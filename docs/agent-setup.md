# Agent 安装引导

把下面整段复制给你的 coding agent（Claude Code、Codex、pi 等），按需替换最后一行「我要装的插件」。

---

你正在为 **Rex** 配置插件管理器 **lazy.rex**。请按下面的步骤在本机完成安装与配置，不要自行发明选项。

## 唯一事实来源

- 仓库与文档：<https://github.com/TaterDoge/lazy.rex>
- 引导代码：<https://raw.githubusercontent.com/TaterDoge/lazy.rex/main/examples/lua/config/lazy.lua>
- 示例配置入口：<https://raw.githubusercontent.com/TaterDoge/lazy.rex/main/examples/init.lua>

先读这三处再动手。README 里的 `setup` 选项表、插件 spec 字段表和「安全与限制」一节是最新契约；未列出的选项会直接报错，不会静默忽略。

## 环境前提

依次确认，缺一项就停下并告诉我：

1. `rex --version` 可运行（需要 Lua 5.1、`rex.exec`、`rex.action`、`rex.log`）。
2. `git`、POSIX `sh`、`find`、`mkdir`、`mv`、`rm` 存在；系统为 macOS 或 Linux。
3. 能访问 GitHub，Git 凭证可非交互使用（管理器禁止交互式凭证提示）。
4. 运行 Rex 服务端的机器是本机，不是远程客户端。

## 步骤

1. **定位 Rex 配置目录，不要写死 `~/.config/rex`。**
   按 `$REX_CONFIG` → `$XDG_CONFIG_HOME/rex` → `~/.config/rex` 的顺序找到实际生效的那个，并用 `rex config check`（先看下面警告）或 `package.path` 的实际值交叉确认。后续路径都相对这个目录。
2. **新增 `<配置目录>/lua/config/lazy.lua`**，内容与上游 `examples/lua/config/lazy.lua` 一致，只按需改远端地址。
   它负责：管理器缺失时用 Git clone 安装、把管理器加入 `package.path`、调用 `require("lazy").setup`。
3. **在 `<配置目录>/init.lua` 中加载它**，追加在现有内容之后：

   ```lua
   local config = assert(package.path:match("^(.-)%?%.lua;"), "cannot locate Rex config")
   package.path = config .. "lua/?.lua;" .. config .. "lua/?/init.lua;" .. package.path
   require("config.lazy")
   ```

   保留 `init.lua` 里已有的 `rex.bind(...)`，不要整份替换。
4. **建 `<配置目录>/lua/plugins/`**，一个插件一个文件，返回 spec 或 spec 列表：

   ```lua
   return {
     "owner/repo",            -- 或完整 Git URL，或绝对路径；本地插件用 dir = "/abs/path"
     main = "module-name",    -- 插件导出的 Lua 模块名
     opts = { key = "value" },-- 传给插件 setup(opts)
   }
   ```

   字段只有：`[1]`、`dir`、`url`、`name`、`enabled`、`init`、`opts`、`main`、`config`。
   本地插件设 `dir`（绝对路径，不支持 `~`），此时不由管理器安装或更新。
5. **验证**：

   ```sh
   rex config check
   rex --timeout 30s do lazy_status
   ```

   要求：没有 Lua 错误；每个目标插件 `installed = true`、`loaded = true`、无加载错误。
6. **汇报**：每个插件的实际安装路径、加载状态、以及下一步可用的命令（`lazy_install` / `lazy_update plugin=<name>` / `rex config reload`）。

## 硬性约束

- **`rex config check` 也会执行引导和自动安装，它不是只读检查。** 会联网并同步等待，执行前先告诉我；如果只想检查语法，先确认管理器是否已装好。
- 插件安装位置：`root`，默认 `$XDG_DATA_HOME/rex/lazy`，未设置时为 `~/.local/share/rex/lazy`；普通插件落在 `<root>/<name>`，管理器自身落在 `<数据目录>/rex/lazy/lazy.rex`。要换位置只在 `setup` 里传绝对路径的 `root`，改 `root` 不会搬迁管理器。
- 不要手工 clone 插件到 `root` 之外，也不要编辑已安装插件目录中的代码——更新只允许干净 checkout 的 `git pull --ff-only`。
- 路径不做 `~` 展开，必须给绝对路径。
- 每次 Rex 配置加载只调用一次 `setup`；不要包成函数循环调用。
- 引导最多等 20 秒，每轮安装/更新动作共用 20 秒预算；超时就改用 `plugin=<短名>` 分批，不要加大超时或并发乱试。
- 异常中断可能留下 `<目录>.lazy-rex-lock`；确认没有任务运行后再处理，不要盲目删除。
- 不要删改我配置目录里与本任务无关的模块、绑定和注释。
- 没有 `opts` 或 `config = true` 的插件不会被自动 `setup`，只是进入 `package.path`；如果你希望它自动初始化，就显式写上 `opts`（即使为空表）。

## 完成标准

- `rex config check` 通过。
- `rex --timeout 30s do lazy_status` 中所有目标插件已安装且已加载。
- 配置目录里只新增/修改了 `init.lua`、`lua/config/lazy.lua`、`lua/plugins/*.lua` 这几类文件。
- 用文字告诉我：配置目录路径、插件安装路径、验证命令的实际输出摘要。

我要装的插件：`<按 "owner/repo + 需要的 opts" 填写>`