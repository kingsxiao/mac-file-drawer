# 统一入口：make app / install / uninstall / dmg / test / clean
# 脚本统一用 `zsh ./xxx.sh` 调用：克隆后无论执行位如何都能直接 make
# ARGS 可透传给脚本，如：make install ARGS="--app-dir /tmp/demo --no-launch"

.PHONY: app install uninstall dmg test clean help

help:            ## 显示所有目标
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-12s %s\n", $$1, $$2}'

app:             ## 构建 build/FileDrawer.app（UNIVERSAL=1 出通用二进制）
	zsh ./make_app.sh $(if $(UNIVERSAL),--universal) $(ARGS)

install:         ## 一键安装到 /Applications 并启动（UNIVERSAL=1 / NO_LAUNCH=1 / ARGS="--app-dir …"）
	zsh ./install.sh $(if $(UNIVERSAL),--universal) $(if $(NO_LAUNCH),--no-launch) $(ARGS)

uninstall:       ## 卸载应用（PURGE=1 连收件箱数据一并删除；ARGS="--app-dir …"）
	zsh ./uninstall.sh $(if $(PURGE),--purge-data) $(ARGS)

dmg:             ## 生成分发用 DMG（UNIVERSAL=1 出通用版）
	zsh ./make_dmg.sh $(if $(UNIVERSAL),--universal) $(ARGS)

test:            ## 运行单元测试
	@DEV="$${DEVELOPER_DIR:-}"; [[ -d "$$DEV" ]] || DEV=/Applications/Xcode.app/Contents/Developer; [[ -d "$$DEV" ]] || DEV="$$(xcode-select -p)"; DEVELOPER_DIR="$$DEV" swift test

smoke-automation: ## 自动化接口端到端冒烟（需已构建 .app；本机有数据时自动备份-恢复）
	zsh ./scripts/smoke_automation.sh --isolated

clean:           ## 清理构建产物
	swift package clean
	rm -rf build
