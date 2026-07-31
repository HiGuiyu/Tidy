# Tidy for iPhone

> 随手收进来,随时理清,只看下一步。

Tidy macOS 的移动伴侣,同时是可离线独立工作的 GTD 执行端。
设计依据:`Tidy-iPhone-Product-Design.docx` v0.1。

## 构建(需要完整 Xcode)

本仓库开发机仅有 Command Line Tools;iOS SDK 随 Xcode 分发,构建步骤:

```bash
# 1. 从 App Store 安装 Xcode(一次性,约 12GB),然后:
sudo xcode-select -s /Applications/Xcode.app
sudo xcodebuild -license accept

# 2. 生成工程并打开(xcodegen 已通过 brew 安装)
cd ios
xcodegen
open TidyPhone.xcodeproj

# 3. Xcode 里选择你的开发者 Team(Signing & Capabilities)→ 选模拟器或真机 → Run
```

## 当前范围(纵向闭环,本地离线可用)

- **四个顶层区**:今天(可行动简报)/ 收件箱 / 项目 / 清单(Action·Waiting·Someday·Done 分段)
- **全局捕获按钮**:半屏 composer,本地写入成功 → 反馈 → 异步 AI 起草;时间表达自动成提醒;保存后可「马上做(2 分钟)」或「继续添加」
- **理清**:收件箱卡片一键「采纳」草稿;低置信只「回答一个问题」→ AI 重新起草;全屏单卡队列,每 3 条自然停顿
- **执行**:首要下一步一键开始专注(15/25/50 分钟),暂停/继续/超时延长;计时以持久化时间戳为真相,杀进程重启后不虚增、不静默丢失;两分钟即办独立倒计时,到时询问实际结果
- **项目**:目的/期望结果、当前下一步、顺序行动链(完成解锁)、添加进展、暂停/完成
- **共享核心**:与 Mac 端同一批平台无关源码(实体/GRDB 库/日期解析/拼音搜索/AI 客户端/埋点/记忆),同一套数据库 schema

## 平台分工(与设计文档一致)

- iPhone:随身捕获、碎片理清、移动执行;**不**直接管理 Mac 文件
- Mac:PARA 目录真相源、文件归档/移动/标签、深度工作台

## 路线图(按文档 Phase)

1. **同步基建**(做 UI 扩展前的前置):UUID / outbox / tombstone / FieldStamp 冲突规则 → CloudKit 私有库 + CKSyncEngine
2. **系统入口**:Share Extension(App Group)、App Intents(捕获/开始专注/完成)、锁屏与主屏组件
3. **Live Activity**:专注与两分钟即办上灵动岛(仅表达进行中的活动,空闲不占岛)
4. 语音捕获、照片/文件附件(App Group staging)、MacCommand 跨端文件指令
