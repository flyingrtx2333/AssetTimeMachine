# 资产时光机 App Store 上架填写资料草案

> 适用范围：中文区（zh-CN）首版上架资料草案
> 当前截图素材目录：`marketing/app-store/2026-05-08-iphone17promax/`
> 官方截图规格参考：App Store Connect `Screenshot specifications`

---

## 1. 基础信息

### App 名称
- 中文：**资产时光机**
- 英文：**Asset Time Machine**

### Subtitle（副标题，建议二选一）
1. **本地优先的个人资产记录与回测**
2. **记录资产，回看趋势，验证策略**

### Primary Category
- **Finance**

### Secondary Category（建议）
- **Productivity**

### 年龄分级建议
- **4+**

### 定价建议
- **免费**（如首版先走自然增长，这样阻力最低）

---

## 2. 关键词 / 标签

### 推荐关键词（可直接填）
`净资产,财富记录,资产配置,投资回测,定投,负债管理,财富趋势,黄金,BTC,纳指`

说明：
- 这一串明显低于 100 字符上限，可直接用。
- 避免和标题、标题副标题重复堆砌同义词，先把“资产记录 + 趋势 + 回测 + 定投”四个核心意图打透。

### 备选关键词
`财富管理,资产追踪,投资复盘,组合回测,长期投资,购买力`

---

## 3. Promotional Text（推广文案）

可直接填写：

**记录资产，也回看资产。资产时光机用本地优先的方式，帮你持续维护资产、负债、净资产与历史趋势，还能做配置回测和定投回测，把“记下来”变成“看明白”。**

---

## 4. Description（App 描述）

可直接填写：

**资产时光机** 是一款本地优先的个人资产记录工具，帮你把每天的资产变化沉淀成长期可回看的财富轨迹。

你可以在一套统一的界面里管理现金、基金、股票、黄金、房产、负债等不同资产，也可以从更长的时间维度，回看自己的净资产变化、资产结构演化，以及购买力与指数对比。

### 你可以用它做什么
- 记录和维护多种资产、负债项目
- 按时间沉淀净资产与总资产快照
- 回看长期趋势，而不是只看某一天结果
- 从购买力、黄金、指数等视角重新理解资产变化
- 对资产配置做历史回测
- 对定投策略做结果复盘
- 使用本地优先的方式保存你的个人资产记录

### 适合谁
- 想长期记录自己资产变化的人
- 既关心净资产，也关心资产结构的人
- 喜欢复盘投资决策，而不是只看短期涨跌的人
- 想把“资产记录”升级为“资产理解”的人

### 为什么叫“时光机”
因为真正有价值的，不只是你今天有多少钱，而是你能不能回到过去，看见自己的路径、选择和变化。

---

## 5. What’s New（版本更新说明）

如果这次是首版上架，可写：

**首个公开版本。支持资产记录、快照回看、时光机趋势查看，以及配置回测和定投回测。**

如果不是首版，而是当前版本更新说明，可写：

**新增配置回测与定投回测结果页展示，优化时光机趋势查看体验，并继续打磨首页与记录页的信息表达。**

---

## 6. 截图上传顺序建议

建议上传以下 5 张：

1. `01-home-dashboard.png`
2. `02-records-editor.png`
3. `03-time-machine.png`
4. `04-allocation-backtest-result.png`
5. `05-dca-backtest-result.png`

### 这套截图当前规格
- 设备：**iPhone 17 Pro Max Simulator**
- 尺寸：**1320 x 2868**
- 符合 6.9" iPhone 截图要求

### 当前状态
当前工程已经收窄为 **iPhone-only**：

- `SUPPORTED_PLATFORMS = iphoneos iphonesimulator`
- `TARGETED_DEVICE_FAMILY = 1`

也就是说，这一版按 iPhone 上架即可，不需要再额外准备 iPad 截图。

---

## 7. App Review Notes（审核备注）

建议填写：

- Core features are available without creating an account.
- The app is designed for personal asset tracking and historical review.
- Optional cloud sync may use Sign in with Apple, but login is not required to review the main experience.
- No paid content or subscription is required to access the core workflow shown in screenshots.

---

## 8. 支持链接 / 营销链接 / 隐私政策链接

提交前建议至少准备这 3 个 URL：

### Support URL
建议地址：
- `https://www.flyingrtx.com/asset-time-machine/support`

建议页面最少包含：
- 产品简介
- 联系方式
- 常见问题
- 版本反馈方式

### Marketing URL
建议地址：
- `https://www.flyingrtx.com/asset-time-machine`

建议页面最少包含：
- 产品卖点
- 截图
- 下载入口 / TestFlight / App Store 入口

### Privacy Policy URL
建议地址：
- `https://www.flyingrtx.com/asset-time-machine/privacy`

建议页面最少包含：
- 是否需要账号
- 是否做云同步
- 数据存储在哪里
- 是否进行广告追踪
- 联系方式

---

## 9. 隐私标签填写建议（先做初稿，提交前再按真实实现核对）

### 可先按这个方向准备
- **Data Used to Track You**：**No**
- **Tracking**：**No**
- **Diagnostics**：若未上报分析，可先填 **No**
- **Financial Info / User Content / Identifiers**：
  - 如果仅本地保存，不上传服务器，可尽量不勾
  - 如果开启云同步并把资产数据上传到你的后端，则需要据实补充

### 结论
如果首版主打“本地优先、无广告、无追踪”，隐私标签会很好看。
但如果已经有账号体系 / 云同步落库，一定要按真实实现核对，不要只按理想状态填。

---

## 10. 上架前检查清单

- [ ] 确认最终标题与副标题
- [ ] 确认关键词是否直接使用推荐串
- [ ] 确认描述是否走当前版本
- [ ] 确认是“首版说明”还是“版本更新说明”
- [ ] 上传 5 张 iPhone 截图
- [x] 已收窄为 iPhone-only 发布
- [ ] 准备 Support URL
- [ ] 准备 Marketing URL
- [ ] 准备 Privacy Policy URL
- [ ] 按真实实现核对隐私标签
- [ ] 补充审核备注

---

## 11. 我给你的建议

如果你想先尽快把包送审，我建议这次走：

- 名称：**资产时光机**
- 副标题：**本地优先的个人资产记录与回测**
- 分类：**Finance / Productivity**
- 关键词：直接用推荐串
- 截图：先上传这 5 张 iPhone 图
- 设备范围：已收窄到 iPhone-only

这一套最稳，也最适合首版。 
