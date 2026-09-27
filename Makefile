PROJECT := DisplayTuner.xcodeproj
SCHEME := DisplayTuner
APP := build/Build/Products/Release/DisplayTuner.app

.PHONY: setup build test test-spm run clean

## setup: 用 XcodeGen 生成 Xcode 工程
setup:
	xcodegen generate

## build: 生成工程并构建 Release 版 App(ad-hoc 签名,可直接运行)
build:
	xcodegen generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release -derivedDataPath build \
		CODE_SIGN_IDENTITY=- \
		build | tail -20

## test: 生成工程并运行 Xcode 单元测试(与 CI 相同命令)
test:
	xcodegen generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO \
		test 2>&1 | tail -40

## test-spm: 直接用 Swift Package Manager 跑核心逻辑测试(快速内环)
test-spm:
	swift test

## run: 构建并启动 App(菜单栏应用,无 Dock 图标)
run: build
	open $(APP)

## clean: 清理所有构建产物
clean:
	rm -rf build .build
