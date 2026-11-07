# lazy.rex

[English](README.md) | 简体中文

采用 lazy.nvim 配置思路的 Rex 插件管理器：声明式 spec、Lua 模块导入、首次启动自安装。
不依赖 Neovim，也不依赖其他 Rex 插件管理器。

**目录结构由你决定。** `config`、`plugins`、`lua` 都不是管理器保留目录。
`import` 按 `package.path` 查找模块；不传 spec 时不导入任何插件。

当前实现聚焦配置组织和安装生命周期，**不是 lazy.nvim 全量移植**。
支持的选项见下文；不支持的选项直接报错，不会静默忽略。

## 环境

- Rex，提供 Lua 5.1、`rex.exec`、`rex.action`、`rex.log`。
- macOS 或 Linux；需要 Git、POSIX shell、`find`、`mkdir`、`mv`、`rm`。
- 安装发生在运行 Rex 服务端的机器，不是远程客户端。

Rex 禁止 `os.execute`、`io.popen`；运行时所有外部命令都通过 `rex.exec`。
独立测试脚本不受此限制。

## 引导安装

完整引导代码在 [`examples/lua/config/lazy.lua`](examples/lua/config/lazy.lua)。
将其放入自己的配置模块，在 `init.lua` 中加载。

引导代码在管理器缺失时执行 Git clone，成功后加入 Lua 搜索路径，再调用 `setup`。
已安装时不联网、不自动更新。

示例使用 `https://github.com/taterdoge/lazy.rex.git` 作为远端地址。

### 一种可选布局

下面只是配置风格，不是目录约束：

```text
~/.config/rex/
├── init.lua
└── lua/
    ├── config/
    │   └── lazy.lua
    └── plugins/
        └── smart-title.lua
```

[`examples/init.lua`](examples/init.lua) 对应的入口：

```lua
-- Rex 已把实际配置目录放在 package.path 最前面。
local config = assert(package.path:match("^(.-)%?%.lua;"))
package.path = config .. "lua/?.lua;" .. config .. "lua/?/init.lua;" .. package.path
require("config.lazy")
```

这种写法跟随 Rex 实际加载的配置目录，支持 `REX_CONFIG`、`XDG_CONFIG_HOME`，
也支持 `rex config check /other/path/init.lua`，不会写死 `~/.config/rex`。
保留你已有的 `rex.bind(...)`，不要用示例覆盖整个 `init.lua`。

也可以把模块放在配置根目录的 `extensions/`，或使用 `bundles.terminal` 这样的命名空间。
只要相应根目录在 `package.path` 中，指定对应 `import` 即可。
引导代码也可以直接放进 `init.lua`，无需 `config.lazy`。

### 本地开发入口

使用本地仓库时，把引导模块内容暂时换成以下代码。开发路径按实际位置修改：

```lua
local dev = assert(os.getenv("HOME")) .. "/Project/lazy.rex"
package.path = dev .. "/lua/?.lua;" .. dev .. "/lua/?/init.lua;" .. package.path
require("lazy").setup("plugins")
```

这会加载本地仓库中的实现，不复制或修改你的配置。
这里的 `plugins` 仍然只是显式指定的模块名。

## setup

三种写法：

```lua
require("lazy").setup("plugins")
```

```lua
require("lazy").setup({
  { import = "plugins" },
  { import = "bundles.terminal" },
}, {
  install = { missing = true },
})
```

```lua
require("lazy").setup({
  spec = { { import = "plugins" } },
  install = { missing = false }, -- 只加载已有插件，缺失的手动安装。
})
```

| 选项 | 默认值 | 含义 |
| --- | --- | --- |
| `spec` | 空 | 插件 spec、spec 列表或导入项；也可作为第一个参数传入 |
| `root` | `$XDG_DATA_HOME/rex/lazy`，否则 `~/.local/share/rex/lazy` | 插件安装根目录，必须是绝对路径 |
| `install.missing` | `true` | 配置加载时安装缺失插件 |

每次 Rex 配置加载只调用一次 `setup`。
管理器默认安装到 `<数据目录>/rex/lazy/lazy.rex`，普通插件安装到 `<root>/<name>`。
修改 `root` 不会自动搬迁管理器；引导模块中的 `lazypath` 单独指定管理器位置。

### import

`{ import = "plugins" }` 会导入找到的：

- `plugins.lua`。
- `plugins/init.lua`。
- `plugins/*.lua`。
- `plugins/*/init.lua`。

先读取 `plugins.lua`，再按模块名排序读取目录内容，`init.lua` 最先。
不递归读取任意深度的文件；更深层级通过显式 `import` 加入。
同一路径的导入文件不会重复执行；循环导入、语法错误、无效返回值会报出源文件。
空目录或 `return {}` 可以表示空 spec；找不到导入模块则报错。

插件文件返回一条 spec 或 spec 列表：

```lua
return {
  "taterdoge/smart-title-rex",
  main = "smart-title-rex",
  opts = {
    api_key = os.getenv("OPENAI_API_KEY") or "",
    model = "gpt-4o-mini",
  },
}
```

所有 spec 校验完成后才开始安装。
同名插件会报错；不同仓库同名时通过 `name` 区分。
当前不做重复声明合并。

## 插件 spec

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `[1]` | string | `owner/repo`、完整 Git URL 或本地绝对路径 |
| `dir` | string | 本地插件绝对路径，不由管理器安装或更新 |
| `url` | string | 自定义 Git URL，可代替 `[1]` |
| `name` | string | 插件名和安装目录名，默认取来源末段并去掉 `.git` |
| `enabled` | boolean / function | `false` 或函数返回 `false` 时跳过安装和加载 |
| `init` | function(plugin) | 启动初始化；所有 `init` 都先于任何 `config` 执行 |
| `opts` | table / function(plugin, opts) | 传给默认 `setup`；函数可修改 opts 或返回替代表 |
| `main` | string | 默认 `setup` 要加载的 Lua 模块，可显式指定 |
| `config` | true / function(plugin, opts) | `true` 调用默认 `setup`；函数替代默认行为 |

`[1]`、`dir`、`url` 至少提供一个。路径不做 `~` 展开。
只使用 `dir` 也有效；末段含特殊字符时可设置合法 `name`。
插件名只允许字母、数字、下划线、点、短横线；不能是 `.`、`..`、`lazy.rex`。
`lazy` Lua 命名空间保留给管理器。

```lua
return {
  dir = "/absolute/path/to/my-plugin",
  name = "my-plugin",
  opts = function(plugin, opts)
    opts.message = plugin.name
  end,
}
```

### 加载语义

插件可使用 Rex 专用 `rex/lua/` 布局或标准 `lua/` 布局：

```text
my-plugin/
├── rex/lua/          -- 该目录存在时优先
│   └── my-plugin/
│       └── init.lua
└── lua/              -- 回退布局或标准 Lua 模块布局
    └── my-plugin/
        └── init.lua
```

管理器为每个插件只选择一个根：`rex/lua/` 存在时选它，否则选 `lua/`。
它把所选根的 `<root>/?.lua`、`<root>/?/init.lua` 加入 `package.path`，并用同一个根推断 `main`；两个根不会混用。
`rex/lua/` 存在但为空或损坏时，不会静默回退到 `lua/`。
它不接管 `require`，保留标准 Lua 的搜索顺序和 `package.loaded` 行为。
模块名共享，插件作者应避免命名冲突。

与 lazy.nvim 一样，**有 `opts` 或 `config = true` 才自动调用默认 `setup(opts)`**。
没有 `opts/config` 的插件只进入搜索路径，可由其他模块手动 `require`。

未指定 `main` 时，优先匹配去掉分隔符和 Lua/Rex 前后缀后的名称，
否则仅在存在唯一顶层 Lua 模块时使用该模块；无法确定时要求显式设置 `main`。
自定义 `config` 不要求插件导出 `setup`。

单个插件的安装、初始化或配置失败会记录日志和状态，不阻断其他插件。
插件 spec 或导入错误则使配置加载失败。

## Rex 动作

```sh
rex do lazy_status
rex --timeout 30s do lazy_install
rex --timeout 30s do lazy_update plugin=smart-title-rex
rex --timeout 60s config reload
```

- `lazy_install`：安装缺失插件；不替换已有 checkout。
- `lazy_update`：仅允许干净 checkout 的 `git pull --ff-only`。
- `lazy_status`：返回目录、启用状态、安装状态、加载状态和加载错误；不联网。

`plugin` 使用短插件名或自定义 `name`，不是 `owner/repo`。
不传 `plugin` 时处理所有启用且由管理器管理的插件，跳过本地插件。
显式指定未知、禁用或本地插件时直接报错。
安装或更新动作不会即时执行插件配置，完成后需重载 Rex 配置。

## 安全与限制

- 首次引导和缺失插件安装会联网，且同步等待；已安装插件启动时不 fetch。
- **`rex config check` 也会执行引导与自动安装。** 它不是本管理器的只读模式。
  已安装管理器时可用 `install = { missing = false }` 禁止检查期间安装普通插件。
- 引导最多等待 20 秒；每轮插件安装或动作共用 20 秒预算。
  超出预算可重试，或用 `plugin=name` 分批执行。
- Git 禁止交互式凭证提示；需要事先配置可非交互使用的凭证。
- clone 使用锁目录和临时 checkout，完成后再移动到目标位置。
  不覆盖非 Git 目录、残留目录或断开的符号链接。
- 更新拒绝本地修改、未跟踪文件、不同 origin 和非快进历史；不执行 reset、clean 或强推。
- 异常中断可能留下 `<目录>.lazy-rex-lock`。确认没有安装或更新任务运行后，再手动处理。
- 插件是具有 Rex 服务端权限的受信任 Lua 代码，不是沙箱。
- 当前无事件/按键/require 触发懒加载、依赖解析、版本约束、锁文件、UI、自动清理或自动监视配置。
  模块导入后在配置加载期间初始化；修改声明后执行 `rex config reload`。

## 验证

在仓库根目录运行：

```sh
luajit "tests/test.lua"
# 或
lua "tests/test.lua"

stylua --check "lua" "examples" "tests"
```

测试使用本地 Git 仓库并禁止网络协议，覆盖导入、规格校验、生命周期、安装、更新和失败保护。
安装了 Rex 时，还会检查临时配置的完整自安装链路及离线再次加载；不会重载你的运行配置。
未安装 Rex 时会明确跳过该集成检查。

参考设计：[lazy.nvim](https://github.com/folke/lazy.nvim)。
Rex 接口：[配置文件](https://www.superlogical.com/rex/docs/customize/config)、
[Lua API](https://www.superlogical.com/rex/docs/reference/lua)。
