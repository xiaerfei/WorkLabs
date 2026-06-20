//
//  wl_decoder.h
//  OBSLabs
//
//  Created by erfeixia on 20/06/2026.
//

#ifndef wl_decoder_h
#define wl_decoder_h

#include <stdio.h>
#include <stdlib.h>

// 仅仅告诉外部有这个结构体类型，但不透露里面有什么
typedef struct wl_decoder_t wl_decoder_t;

wl_decoder_t *wl_decoder_create(const char *path);
void wl_decoder_free(wl_decoder_t *decoder);




#endif /* wl_decoder_h */
