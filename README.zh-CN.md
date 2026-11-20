# HF Split Ledger

[English](README.md) · 简体中文

一条命令即可将 Hugging Face Dataset Viewer 上公开数据集的一个分区导入 InterSystems IRIS。每行保留从 0 开始的源行号和完整的 JSON 对象，包括嵌套字段。来源表记录数据集、配置和分区，可据此在 Viewer 中找到原始行并核对内容。

## 从 IRIS 终端运行

核心实现位于 [HFSplit.Importer](src/HFSplit.Importer.cls)。ObjectScript 负责向 Hugging Face 发起 HTTPS 请求、逐页验证 JSON、管理来源键并在 IRIS 事务内写入记录。已有分区沿用原来的来源键。

1. 将仓库挂载或复制到 IRIS 实例可读的目录（示例为 `/app`）。在目标命名空间编译类。

```objectscript
set sc=$system.OBJ.Load("/app/src/HFSplit.Importer.cls","ck")
do $system.Status.DisplayError(sc)
```

2. 准备启用对端证书验证的 IRIS 客户端 TLS 配置。下面是管理员在干净的 Linux IRIS 2026.2 容器的 `%SYS` 命名空间中创建配置的示例。其他系统请指定实际的受信任 CA 文件。

```objectscript
set p("Enabled")=1,p("Type")=0,p("VerifyPeer")=2
set p("CAFile")="/etc/ssl/certs/ca-certificates.crt"
set sc=##class(Security.SSLConfigs).Create("HFViewerTLS",.p)
do $system.Status.DisplayError(sc)
```

3. 回到应用命名空间，运行导入。下列调用返回 `101`。省略第四个参数即可导入整个分区；如需使用现有 TLS 配置，可将名称作为第五个参数传入。账号须能在 `HFSplit` 模式建表并读写应用表，IRIS 主机须能通过 HTTPS 访问 Dataset Viewer。

```objectscript
write ##class(HFSplit.Importer).Import("cornell-movie-review-data/rotten_tomatoes","default","test",101)
```

## 从命令行调用

命令行兼容入口使用 Python 3.10+ 和官方驱动，将参数传给上述 ObjectScript 类。设置 `HF_VIEWER_TLS` 可选择 IRIS 访问 Viewer 时使用的配置。远程连接 IRIS 的客户端可通过 `IRIS_SSL_CONFIG` 指定其数据库 TLS 配置。 命令行使用的账号还须有权在应用命名空间通过 IRIS Native API 调用导入类。

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
export IRIS_DSN='localhost:1972/USER'
export IRIS_USER='your-import-user'
# Set IRIS_PASSWORD in your shell or secret manager.
python ledger.py cornell-movie-review-data/rotten_tomatoes default test --limit 101
```

示例预期输出为 `Committed 101 rows for cornell-movie-review-data/rotten_tomatoes / default / test.`。省略 `--limit` 即可刷新整个分区。在同一 IRIS 命名空间中运行下列 SQL，可以查看第一页的最后一行和第二页的第一行。

```sql
SELECT r.SourceRow, r.JsonBody
FROM HFSplit.Records r
JOIN HFSplit.Sources s ON s.SourceKey = r.SourceKey
WHERE s.DatasetName = 'cornell-movie-review-data/rotten_tomatoes'
  AND s.ConfigName = 'default' AND s.SplitName = 'test'
  AND r.SourceRow IN (99, 100)
ORDER BY r.SourceRow
```

## 刷新规则

每个“数据集、配置、分区”组合有独立的来源键。完整刷新在同一事务内新增或更新记录，并清除超出当前分区行数的旧记录。设置行数上限时，只更新指定的前几行，后续记录保留原值。分页读取或数据库写入失败会回滚本次刷新。该工具适合能在单个 IRIS 事务内完成导入的中小分区。

数据源须通过公开的 Dataset Viewer API 提供完整的 JSON 行。导入器逐页检查总行数、行号和字段完整性。发现字段截断或行号不连续时会中止导入。服务端提供版本响应头时，导入器还会检查各页的版本是否一致。缺少该响应头时无法锁定不可变版本。运行期间需要能访问 Viewer。

## 验证

在专用测试命名空间中，先编译提供确定性分页响应的测试类，再用相同命名空间的连接配置运行以下命令。

```objectscript
set sc=$system.OBJ.Load("/app/tests/HFSplitTest.Fixture.cls","ck")
do $system.Status.DisplayError(sc)
```

```sh
python -m unittest -v
python verify_live.py
```

原生测试覆盖跨页刷新、保留后缀、空分区，以及后续页截断或来源版本变化时的事务回滚。在线脚本两次导入完整公开分区，对照源总行数和跨页的两条 JSON。IRIS 2026.2 实测两次均为 1,066 行。

接口文档见 [Dataset Viewer 分页接口](https://huggingface.co/docs/dataset-viewer/en/rows) 和 [InterSystems Python DB-API](https://docs.intersystems.com/irislatest/csp/docbook/DocBook.UI.Page.cls?KEY=BPYDBAPI_refapi)。

本项目对应的社区悬赏题目为[将 Hugging Face 数据集导入 IRIS](https://ideas.intersystems.com/ideas/DPI-I-543)。
