// C interface to Anki's Rust backend. See rust/ankibridge/src/lib.rs for the
// ownership rules; every AnkiBuffer you receive must go to anki_buffer_free.

#ifndef ANKIBRIDGE_H
#define ANKIBRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AnkiBackendHandle AnkiBackendHandle;

typedef struct AnkiBuffer {
    uint8_t *data;
    size_t len;
} AnkiBuffer;

AnkiBackendHandle *anki_backend_new(const uint8_t *init, size_t init_len, AnkiBuffer *out_error);
void anki_backend_free(AnkiBackendHandle *backend);

bool anki_backend_run(const AnkiBackendHandle *backend,
                      uint32_t service,
                      uint32_t method,
                      const uint8_t *input,
                      size_t input_len,
                      AnkiBuffer *out);

void anki_buffer_free(AnkiBuffer buffer);

bool anki_init_logging(const char *path);
AnkiBuffer anki_buildhash(void);

#ifdef __cplusplus
}
#endif

#endif
