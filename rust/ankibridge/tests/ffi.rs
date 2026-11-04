// Copyright: the ankios authors.
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html

//! Exercises the C ABI exactly the way the Swift layer does: protobuf bytes in,
//! protobuf bytes out, with service/method indices resolved by name through
//! the same `get_services` function swiftgen uses. If these pass, the Swift
//! wrappers are calling the right RPCs.

use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::OnceLock;

use anki::sync::http_server::default_ip_header;
use anki::sync::http_server::SimpleServer;
use anki::sync::http_server::SyncServerConfig;
use anki_proto::backend::BackendError;
use anki_proto::backend::BackendInit;
use anki_proto_gen::get_services;
use ankibridge::*;
use prost::Message;
use prost_reflect::DescriptorPool;

struct Rpc {
    pool: DescriptorPool,
}

impl Rpc {
    fn get() -> &'static Rpc {
        static RPC: OnceLock<Rpc> = OnceLock::new();
        RPC.get_or_init(|| {
            let bytes = std::fs::read(env!("DESCRIPTORS_BIN")).expect("descriptors");
            Rpc {
                pool: DescriptorPool::decode(bytes.as_ref()).unwrap(),
            }
        })
    }

    fn index(&self, method: &str) -> (u32, u32) {
        let (_, services) = get_services(&self.pool);
        for s in &services {
            if s.name == "BackendFrontendService" {
                continue;
            }
            if let Some(m) = s.all_methods().find(|m| m.name == method) {
                return (s.index as u32, m.index as u32);
            }
        }
        panic!("no such method {method}");
    }
}

struct Backend(*mut AnkiBackendHandle);
unsafe impl Send for Backend {}
unsafe impl Sync for Backend {}

impl Backend {
    fn new() -> Self {
        let init = BackendInit {
            preferred_langs: vec!["en".into()],
            ..Default::default()
        }
        .encode_to_vec();
        let mut err = AnkiBuffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let h = unsafe { anki_backend_new(init.as_ptr(), init.len(), &mut err) };
        assert!(!h.is_null());
        Backend(h)
    }

    fn call_raw(&self, method: &str, input: &[u8]) -> Result<Vec<u8>, BackendError> {
        let (svc, m) = Rpc::get().index(method);
        let mut out = AnkiBuffer {
            data: std::ptr::null_mut(),
            len: 0,
        };
        let ok = unsafe { anki_backend_run(self.0, svc, m, input.as_ptr(), input.len(), &mut out) };
        let bytes = if out.data.is_null() {
            vec![]
        } else {
            unsafe { std::slice::from_raw_parts(out.data, out.len) }.to_vec()
        };
        unsafe { anki_buffer_free(out) };
        if ok {
            Ok(bytes)
        } else {
            Err(BackendError::decode(bytes.as_slice()).unwrap())
        }
    }

    fn call<I: Message, O: Message + Default>(&self, method: &str, input: I) -> O {
        let bytes = self
            .call_raw(method, &input.encode_to_vec())
            .unwrap_or_else(|e| panic!("{method} failed: {e:?}"));
        O::decode(bytes.as_slice()).unwrap()
    }

    fn open(&self, dir: &PathBuf) {
        std::fs::create_dir_all(dir).unwrap();
        let req = anki_proto::collection::OpenCollectionRequest {
            collection_path: dir.join("collection.anki2").to_string_lossy().into(),
            media_folder_path: dir.join("collection.media").to_string_lossy().into(),
            media_db_path: dir.join("collection.media.db2").to_string_lossy().into(),
        };
        let _: Empty = self.call("open_collection", req);
    }

    fn add_basic_note(&self, front: &str, back: &str) {
        let names: anki_proto::notetypes::NotetypeNames = self.call("get_notetype_names", Empty {});
        let basic = names.entries.iter().find(|e| e.name == "Basic").unwrap();
        let mut note: anki_proto::notes::Note = self.call(
            "new_note",
            anki_proto::notetypes::NotetypeId { ntid: basic.id },
        );
        note.fields = vec![front.into(), back.into()];
        let _: anki_proto::notes::AddNoteResponse = self.call(
            "add_note",
            anki_proto::notes::AddNoteRequest {
                note: Some(note),
                deck_id: 1,
            },
        );
    }

    fn queue(&self) -> anki_proto::scheduler::QueuedCards {
        self.call(
            "get_queued_cards",
            anki_proto::scheduler::GetQueuedCardsRequest {
                fetch_limit: 1,
                intraday_learning_only: false,
            },
        )
    }

    fn close(&self) {
        let _: Empty = self.call(
            "close_collection",
            anki_proto::collection::CloseCollectionRequest {
                downgrade_to_schema11: false,
            },
        );
    }
}

impl Drop for Backend {
    fn drop(&mut self) {
        unsafe { anki_backend_free(self.0) };
    }
}

type Empty = anki_proto::generic::Empty;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "ankibridge-test-{}-{}-{}",
        name,
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64
}

/// Answer the top card the way the iOS reviewer does.
fn answer_top_card(b: &Backend, rating: anki_proto::scheduler::card_answer::Rating) {
    use anki_proto::scheduler::CardAnswer;
    let queued = b.queue().cards.remove(0);
    let states = queued.states.unwrap();
    let new_state = match rating {
        anki_proto::scheduler::card_answer::Rating::Again => states.again,
        anki_proto::scheduler::card_answer::Rating::Hard => states.hard,
        anki_proto::scheduler::card_answer::Rating::Good => states.good,
        anki_proto::scheduler::card_answer::Rating::Easy => states.easy,
    };
    let _: anki_proto::collection::OpChanges = b.call(
        "answer_card",
        CardAnswer {
            card_id: queued.card.unwrap().id,
            current_state: states.current,
            new_state,
            rating: rating as i32,
            answered_at_millis: now_secs() * 1000,
            milliseconds_taken: 4000,
        },
    );
}

#[test]
fn errors_come_back_as_backend_error() {
    let b = Backend::new();
    // No collection open yet.
    let err = b
        .call_raw("deck_tree", &anki_proto::decks::DeckTreeRequest { now: 0 }.encode_to_vec())
        .unwrap_err();
    assert!(!err.message.is_empty());
    // Out-of-range indices must not crash.
    let mut out = AnkiBuffer {
        data: std::ptr::null_mut(),
        len: 0,
    };
    let ok = unsafe { anki_backend_run(b.0, 999, 0, std::ptr::null(), 0, &mut out) };
    assert!(!ok);
    unsafe { anki_buffer_free(out) };
}

#[test]
fn study_flow() {
    let dir = temp_dir("study");
    let b = Backend::new();
    b.open(&dir);
    b.add_basic_note("front <b>text</b>", "back");

    let tree: anki_proto::decks::DeckTreeNode =
        b.call("deck_tree", anki_proto::decks::DeckTreeRequest { now: now_secs() });
    let default = &tree.children[0];
    assert_eq!(default.name, "Default");
    assert_eq!(default.new_count, 1);

    let _: anki_proto::collection::OpChanges = b.call(
        "set_current_deck",
        anki_proto::decks::DeckId {
            did: default.deck_id,
        },
    );
    let queue = b.queue();
    assert_eq!(queue.new_count, 1);
    let card = queue.cards[0].card.clone().unwrap();

    let rendered: anki_proto::card_rendering::RenderCardResponse = b.call(
        "render_existing_card",
        anki_proto::card_rendering::RenderExistingCardRequest {
            card_id: card.id,
            browser: false,
            partial_render: false,
        },
    );
    let question: String = rendered
        .question_nodes
        .iter()
        .filter_map(|n| match &n.value {
            Some(anki_proto::card_rendering::rendered_template_node::Value::Text(t)) => {
                Some(t.clone())
            }
            _ => None,
        })
        .collect();
    assert!(question.contains("front <b>text</b>"), "{question}");
    assert!(rendered.css.contains(".card"));

    let labels: anki_proto::generic::StringList = b.call(
        "describe_next_states",
        queue.cards[0].states.clone().unwrap(),
    );
    assert_eq!(labels.vals.len(), 4);

    answer_top_card(&b, anki_proto::scheduler::card_answer::Rating::Easy);
    let after = b.queue();
    assert_eq!(after.new_count, 0);
    assert!(after.cards.is_empty());

    // Undo puts it back.
    let _: anki_proto::collection::OpChangesAfterUndo = b.call("undo", Empty {});
    assert_eq!(b.queue().new_count, 1);

    b.close();
    std::fs::remove_dir_all(dir).ok();
}

/// Full upload from one device, full download to a fresh device, then a normal
/// sync of a review back. This is the "use my existing decks and sync back"
/// path, against Anki's own self-hosted sync server.
#[test]
fn sync_roundtrip_against_local_server() {
    use anki_proto::sync::sync_collection_response::ChangesRequired;
    use anki_proto::sync::*;

    let server_dir = temp_dir("server");
    std::env::set_var("SYNC_USER1", "user:pass");
    let (addr_tx, addr_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async move {
            let config = SyncServerConfig {
                host: IpAddr::from([127, 0, 0, 1]),
                port: 0,
                base_folder: server_dir,
                ip_header: default_ip_header(),
            };
            let (addr, fut) = SimpleServer::make_server(config).await.unwrap();
            addr_tx.send(addr).unwrap();
            fut.await.unwrap();
        });
    });
    let addr = addr_rx.recv().unwrap();
    let endpoint = format!("http://{addr}/");

    let login = |b: &Backend| -> SyncAuth {
        b.call(
            "sync_login",
            SyncLoginRequest {
                username: "user".into(),
                password: "pass".into(),
                endpoint: Some(endpoint.clone()),
            },
        )
    };
    let sync = |b: &Backend, auth: &SyncAuth| -> SyncCollectionResponse {
        b.call(
            "sync_collection",
            SyncCollectionRequest {
                auth: Some(auth.clone()),
                sync_media: false,
            },
        )
    };

    // Bad password surfaces as a sync auth error.
    let a = Backend::new();
    let err = a
        .call_raw(
            "sync_login",
            &SyncLoginRequest {
                username: "user".into(),
                password: "wrong".into(),
                endpoint: Some(endpoint.clone()),
            }
            .encode_to_vec(),
        )
        .unwrap_err();
    assert_eq!(
        err.kind,
        anki_proto::backend::backend_error::Kind::SyncAuthError as i32
    );

    // Device A: has cards, server is empty -> full upload.
    let dir_a = temp_dir("a");
    a.open(&dir_a);
    a.add_basic_note("q1", "a1");
    a.add_basic_note("q2", "a2");
    let mut auth_a = login(&a);
    auth_a.endpoint = Some(endpoint.clone());
    let out = sync(&a, &auth_a);
    assert_eq!(out.required(), ChangesRequired::FullUpload);
    let _: anki_proto::generic::Empty = a.call(
        "full_upload_or_download",
        FullUploadOrDownloadRequest {
            auth: Some(auth_a.clone()),
            upload: true,
            server_usn: None,
        },
    );

    // Device B (the phone): empty collection -> full download.
    let b = Backend::new();
    let dir_b = temp_dir("b");
    b.open(&dir_b);
    let mut auth_b = login(&b);
    auth_b.endpoint = Some(endpoint.clone());
    let out = sync(&b, &auth_b);
    assert_eq!(out.required(), ChangesRequired::FullDownload);
    let _: anki_proto::generic::Empty = b.call(
        "full_upload_or_download",
        FullUploadOrDownloadRequest {
            auth: Some(auth_b.clone()),
            upload: false,
            server_usn: None,
        },
    );
    // Collection was reopened by the backend and now has A's cards.
    assert_eq!(b.queue().new_count, 2);

    // Review on B, normal sync up, normal sync down on A.
    answer_top_card(&b, anki_proto::scheduler::card_answer::Rating::Easy);
    assert_eq!(sync(&b, &auth_b).required(), ChangesRequired::NoChanges);
    assert_eq!(sync(&a, &auth_a).required(), ChangesRequired::NoChanges);
    assert_eq!(a.queue().new_count, 1);

    a.close();
    b.close();
}
