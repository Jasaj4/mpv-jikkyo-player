# jikkyo-player Makefile (macOS / Linux)
# Windowsでは install.ps1 を使用してください。
#
# Usage:
#   git clone <repo> ~/.config/mpv/scripts/jikkyo-player
#   cd ~/.config/mpv/scripts/jikkyo-player
#   make install
#
# Options:
#   make install NO_ARIB=1       # ARIB字幕なし

# Detect mpv config dir from install location:
#   <mpv-config>/scripts/jikkyo-player/Makefile -> <mpv-config>
# CURDIR resolves symlinks, so use MPV_DIR override for symlinked installs.
# For direct clone (normal case), CURDIR/../../ works correctly.
MPV_DIR ?= $(abspath $(CURDIR)/../..)
OPTS_DIR = $(MPV_DIR)/script-opts
VENDOR_DIR = $(CURDIR)/vendor
ARIB_REPO = https://github.com/Jasaj4/arib-ts2ass.js.git
ARIB_DIR = $(VENDOR_DIR)/arib-ts2ass.js

install: update install-core
ifndef NO_ARIB
	$(MAKE) install-arib
endif
	@echo ""
	@echo "=== セットアップ完了 ==="
	@echo "mpv config:    $(MPV_DIR)"
	@echo "スクリプト:    $(CURDIR)/main.lua"
	@echo "設定ファイル:  $(OPTS_DIR)/jikkyo-player.conf (手動作成)"
ifndef NO_ARIB
	@echo "ARIB字幕:     $(ARIB_DIR)"
endif
	@echo "CLI:           $(CURDIR)/bin/jikkyo-player"
	@echo ""

install-core:
	chmod +x bin/jikkyo-player
	@# 日本の放送用幅1440→1920字幕まで伸ばされる対策
	@if [ -f "$(MPV_DIR)/mpv.conf" ] && grep -q '^sub-ass-use-video-data=' "$(MPV_DIR)/mpv.conf"; then \
		tmp_conf="$(MPV_DIR)/mpv.conf.tmp"; \
		sed 's/^sub-ass-use-video-data=.*/sub-ass-use-video-data=none/' "$(MPV_DIR)/mpv.conf" > "$$tmp_conf" && \
		mv "$$tmp_conf" "$(MPV_DIR)/mpv.conf"; \
	else \
		echo "" >> "$(MPV_DIR)/mpv.conf"; \
		echo "# 日本の放送用幅1440→1920字幕まで伸ばされる対策" >> "$(MPV_DIR)/mpv.conf"; \
		echo "sub-ass-use-video-data=none" >> "$(MPV_DIR)/mpv.conf"; \
	fi

install-arib:
	@mkdir -p $(VENDOR_DIR)
	@if [ -d "$(ARIB_DIR)/.git" ]; then \
		echo "arib-ts2ass.js: 更新中..."; \
		cd "$(ARIB_DIR)" && git pull --recurse-submodules && npm install; \
	else \
		echo "arib-ts2ass.js: インストール中..."; \
		git clone --recursive $(ARIB_REPO) "$(ARIB_DIR)" && \
		cd "$(ARIB_DIR)" && npm install; \
	fi

update:
	@echo "jikkyo-player: 更新中..."
	@git pull

.PHONY: install install-core install-arib update
