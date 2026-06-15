# M0 · decode_one_frame —— 链接 brew 安装的 FFmpeg
#
#   brew install ffmpeg   # 一并装好开发库 + pkg-config 描述文件
#   make                  # 编译
#   make clean            # 清理

CC     = clang
CFLAGS = -g -Wall -O0

# 优先用 pkg-config 自动找 FFmpeg 的头/库路径
FFMPEG_CFLAGS := $(shell pkg-config --cflags libavformat libavcodec libavutil 2>/dev/null)
FFMPEG_LIBS   := $(shell pkg-config --libs   libavformat libavcodec libavutil 2>/dev/null)

# 兜底：pkg-config 没配好时，手动指定 brew 前缀（Apple Silicon 默认 /opt/homebrew；Intel 用 /usr/local）
ifeq ($(strip $(FFMPEG_LIBS)),)
FFMPEG_PREFIX ?= /opt/homebrew
FFMPEG_CFLAGS := -I$(FFMPEG_PREFIX)/include
FFMPEG_LIBS   := -L$(FFMPEG_PREFIX)/lib -lavformat -lavcodec -lavutil
endif

decode_one_frame: decode_one_frame.c
	$(CC) $(CFLAGS) $(FFMPEG_CFLAGS) -o $@ $< $(FFMPEG_LIBS) -lm

clean:
	rm -f decode_one_frame *.bmp

.PHONY: clean
