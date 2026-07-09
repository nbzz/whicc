#!/usr/bin/env python3
"""模型下载守护进程。

macui 设置界面通过两个文件与本守护进程通信：

1. 请求文件 /tmp/whicc-out/model_download_request.json
   格式：{"action": "download"|"cancel", "model_id": "..."}
   macui 写 → 守护进程读

2. 进度文件 /tmp/whicc-out/model_download.jsonl
   每行一个事件（started/progress/completed/failed/cancelled）
   守护进程追加 → macui 订阅

设计原则（苹果最佳实践 + 与现有架构一致）：
- 单独进程，nohup 后台跑（跟 glossary_refresher.py 同款模式）
- 下载位置 = macui 期望的位置 ~/Library/Application Support/whicc/models/
  （model_id 的 "/" 替换为 "--"，与 whicc.py / ModelState 同款约定）
- 进度写 JSONL 追加模式，原子写（每次写一行 flush + fsync）
- 支持取消（检查 request 文件的 cancel 动作）

进度用 huggingface_hub 的 tqdm_class 钩子拿实时值——每个 chunk 写一次
进度事件，macui 端读到后实时更新 ProgressView，不需要靠目录大小估算。
"""
import argparse
import json
import os
import sys
import time
import threading
import traceback


# ── 路径常量（与 ModelState 同款） ──────────────────────────
OUT_DIR = "/tmp/whicc-out"
MODELS_DIR = os.path.expanduser("~/Library/Application Support/whicc/models")
REQUEST_FILE = os.path.join(OUT_DIR, "model_download_request.json")
PROGRESS_FILE = os.path.join(OUT_DIR, "model_download.jsonl")
LOG_FILE = "/tmp/model_downloader.log"


# ── 进度文件写入（原子追加，守护进程端） ─────────────────────────────
# 每条事件追加一行 JSON（JSONL 格式），macui 订阅
# - 用 O_APPEND 保证原子性
# - 每行 flush + fsync 保证崩溃时不丢进度
_progress_lock = threading.Lock()


def _emit_event(event: str, model_id: str, **kwargs):
    """写一行进度事件到 JSONL 文件。"""
    # 用 monotonic_ns 而不是 time.time()：daemon 跑一晚上时
    # NTP 校时/夏令时/用户改时间可能让 time.time() 倒退，事件 ts 变负。
    payload = {
        "event": event,
        "model_id": model_id,
        "ts": time.monotonic_ns() / 1e9,  # 保持浮点秒单位（macui 端容易读）
        **kwargs,
    }
    line = json.dumps(payload, ensure_ascii=False) + "\n"
    with _progress_lock:
        try:
            with open(PROGRESS_FILE, "a", encoding="utf-8") as f:
                f.write(line)
                f.flush()
                os.fsync(f.fileno())
        except OSError as e:
            _log(f"emit_event failed: {e}")


def _log(msg: str):
    """守护进程日志：stderr + log 文件，加时间戳，加锁防交错。

    只写文件（BackendLauncher 用 `>>` 重定向 stderr 到同一文件）——避免重复。
    加锁防多个线程/进程并发写时一行被截断成两半。
    """
    import datetime as _dt
    ts = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] [model_downloader] {msg}\n"
    with _progress_lock:
        try:
            sys.stderr.write(line)
            sys.stderr.flush()
        except OSError:
            pass
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(line)
        except OSError:
            pass


# ── 路径辅助 ────────────────────────────────────────────────────────────
def _model_local_path(model_id: str) -> str:
    """HF ID → 本地路径。约定与 whicc.py / ModelState 同款：
    vendor/model → vendor--model（"--" 替换）。"""
    safe = model_id.replace("/", "--")
    return os.path.join(MODELS_DIR, safe)


class DownloadCancelled(Exception):
    """用户取消下载。从进度钩子(JsonlProgress.update → tracker.add_bytes)
    里抛出 — 那是 snapshot_download 过程中唯一的逐 chunk 回调点,也是
    唯一能从外部中断 huggingface_hub 下载线程的地方。异常经 hf 的
    线程池传播回 snapshot_download 抛出,_run() 捕获后静默清退。"""


# ── 自定义 tqdm 类：实时写 JSONL 进度 ──────────────────────────────────
# huggingface_hub 对每个文件创建一个 JsonlProgress 实例。
# 第一个文件下完时 .close() 被调——但整个下载可能还有几十个文件。
# 所以不能在单个实例的 .close() 里写 100%（那会提前显示满）。
#
# 修法：用 _ProgressTracker 实例（每个 DownloadTask 一个）跨文件累加字节。
# tracker 注册到模块级 _trackers_by_model dict，JsonlProgress.update() 通过
# dict 找到当前 model 的 tracker 加字节。进度 = downloaded_bytes / total_bytes。
# total_bytes 从 HfApi.model_info 拿（下载前算好）。
# 100% 由 daemon 在 snapshot_download() 返回后统一写。


class _ProgressTracker:
    """单个下载任务的进度累加器。

    huggingface_hub 对每个文件创建一个 JsonlProgress 实例，
    所有实例共享同一个 tracker 累加字节。线程安全（Lock）。

    之前用模块级 globals（_total_bytes_global / _bytes_downloaded）有严重 bug：
    - 并发下载会互相串改
    - 串行下载第二个模型会接着第一个模型的 _bytes_downloaded 累加
    - 改用类实例属性，每个 DownloadTask 实例自己持有一个

    cancelled: 所属 DownloadTask 的取消标记。add_bytes 在每个 chunk 检查,
    置位即抛 DownloadCancelled 真正中断下载(之前取消只是设标记,
    snapshot_download 从不检查,线程会把整个模型偷偷下完)。
    """

    def __init__(self, cancelled: "threading.Event | None" = None):
        self._lock = threading.Lock()
        self.cancelled = cancelled
        self.total_bytes: int = 0        # 所有文件总大小
        self.downloaded_bytes: int = 0   # 累计已下载
        self.last_emitted_pct: float = -1.0

    def reset(self):
        """下载前重置。"""
        with self._lock:
            self.total_bytes = 0
            self.downloaded_bytes = 0
            self.last_emitted_pct = -1.0

    def set_total(self, total: int):
        """设置所有文件总大小。"""
        with self._lock:
            self.total_bytes = total

    def add_bytes(self, n: int, model_id: str):
        """每个 chunk 后调用：累加字节，pct 变化 >= 1% 时写 JSONL。"""
        if self.cancelled is not None and self.cancelled.is_set():
            # 用户已取消:停发 progress(cancelled 事件已发,再发 progress
            # 会把 macui 的状态从"已取消"翻回"下载中"),并抛异常让
            # huggingface_hub 的下载线程立刻退出。
            raise DownloadCancelled(model_id)
        with self._lock:
            self.downloaded_bytes += n
            if self.total_bytes <= 0:
                return
            pct = min(self.downloaded_bytes / self.total_bytes, 1.0)
            if pct - self.last_emitted_pct >= 0.01 or pct >= 1.0:
                _emit_event("progress", model_id,
                            downloaded_bytes=self.downloaded_bytes,
                            total_bytes=self.total_bytes,
                            pct=round(pct, 4))
                self.last_emitted_pct = pct


# tracker 注册表：modelId → _ProgressTracker 实例
# DownloadTask._run() 启动时 register，结束时 unregister。
# JsonlProgress.update() 通过这个 dict 找到当前下载任务的 tracker。
# 锁：避免 register/unregister 与 update 之间的 race。
# 必须放在 _ProgressTracker 类**下面**——上面的类型注解要能解析到这个类。
_trackers_by_model: dict[str, "_ProgressTracker"] = {}
_trackers_lock = threading.Lock()




class JsonlProgress:
    """自定义进度类，替代 huggingface_hub 的 tqdm。

    huggingface_hub 对每个文件调用：
    - __init__(total=N)   （该文件大小）
    - .update(n)          （每个 chunk）
    - .close()            （该文件下完）

    每个文件一个实例，所以 .close() != 整个下载完成。
    我们只在 .update() 时累加字节到全局计数器，不在 .close() 时写 100%。
    100% 由 daemon 在 snapshot_download() 返回后统一写。
    """

    _model_id: str = ""
    # 类级 _lock：tqdm.contrib.concurrent.ensure_lock 直接访问 tqdm_class._lock
    # （不是 get_lock() 静态方法）。删掉这个文件 concurrent 下载路径就崩。
    # 类属性在所有实例间共享，跟 tqdm 标准行为一致。
    _lock = threading.Lock()

    def __init__(self, *args, **kwargs):
        self.model_id = self._model_id
        self.n = 0
        # huggingface_hub 通过 _create_progress_bar 用 `cls(total=N, **kwargs)` 调
        # 我们的类（huggingface_hub/utils/tqdm.py:337）。后续在
        # _snapshot_download.py:414 会做 `bytes_progress.total += total`，
        # 所以必须保留 self.total 属性（参考标准 tqdm 行为）。
        # 支持两种调用形式：
        # - cls(total=N)  → huggingface_hub 内部路径（kwargs 带 total）
        # - cls(iterable) → 标准 tqdm 路径（args[0] 是 iterable）
        self.total: int = kwargs.get("total", 0)
        # iterable 用法：在 __init__ 里建好 iterator 存起来，__next__ 复用，
        # 避免每次 iter() 重新建（generator 会重置位置）。
        if args and not isinstance(args[0], (int, float)):
            self._iter: object | None = iter(args[0])
        else:
            self._iter = None

    def __iter__(self):
        """标准 tqdm 是可迭代的：包装一个 iterable，边 yield 边更新进度。"""
        return self

    def __next__(self):
        """支持 next() 调用。使用 __init__ 里建好的 iterator。"""
        if self._iter is None:
            raise StopIteration
        try:
            item = next(self._iter)
            self.update(1)
            return item
        except StopIteration:
            raise

    def update(self, n=1):
        self.n += n
        if n > 0:
            # 用全局 dict 查对应 model_id 的 tracker
            # DownloadTask._run() 开始时 register，结束时 unregister
            tracker = _trackers_by_model.get(self.model_id)
            if tracker is not None:
                tracker.add_bytes(n, self.model_id)

    def close(self):
        # 不写 100%——huggingface_hub 对每个文件调 close()，
        # 但整个下载可能还有其他文件没下完。
        # 100% 由 daemon 在 snapshot_download() 返回后统一写。
        pass

    # huggingface_hub 调用的 tqdm 标准 API
    def set_description(self, desc=None, refresh=True):
        pass

    def set_postfix(self, ordered_dict=None, refresh=True, **kwargs):
        pass

    def refresh(self):
        pass

    def display(self, msg=None, pos=None):
        pass

    @staticmethod
    def get_lock():
        return threading.Lock()

    @staticmethod
    def set_lock(lock):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def make_tqdm_class(model_id: str):
    """工厂函数：返回绑定了 model_id 的 JsonlProgress 子类。"""
    return type(
        f"JsonlProgress_{model_id.replace('/', '_')}",
        (JsonlProgress,),
        {"_model_id": model_id},
    )


# ── 下载任务 ────────────────────────────────────────────────────────────
HF_MIRROR_ENDPOINT = "https://hf-mirror.com"


def _hf_endpoint() -> str | None:
    """读 lang_config.json 的下载加速开关。开启 → 返回镜像 endpoint,
    关闭/读不到 → None(走 huggingface.co 官方)。每次下载时现读 —
    用户在设置页切换开关后,下一次下载立即生效,不用重启 daemon。"""
    try:
        with open(os.path.join(OUT_DIR, "lang_config.json"), encoding="utf-8") as f:
            if json.load(f).get("hf_mirror_enabled"):
                return HF_MIRROR_ENDPOINT
    except (OSError, json.JSONDecodeError):
        pass
    return None


class DownloadTask:
    """单个下载任务：管理状态、进度、取消。"""

    def __init__(self, model_id: str):
        self.model_id = model_id
        self.local_path = _model_local_path(model_id)
        self.cancelled = threading.Event()
        self.thread: threading.Thread | None = None

    def start(self):
        """启动后台下载线程（守护进程端的工作线程）。"""
        # 检查 .complete 标记文件（上次成功下载留下的）
        # 之前只看目录非空就跳过——残缺目录（上次下载失败留下的）会误判为"已存在"，
        # 用户用残缺模型发现质量差但没法重下。
        complete_marker = self.local_path + ".complete"
        if os.path.exists(complete_marker):
            _log(f"模型已存在: {self.local_path}（有 .complete 标记），跳过下载")
            _emit_event("completed", self.model_id, total_bytes=0, skipped=True)
            return
        # 残缺目录(无 .complete 标记但有内容 = 上次取消/失败留下的)
        # **不再 rmtree** — huggingface_hub 的 local_dir 下载自带断点续传
        # (etag 校验 + .cache 元数据):重下会跳过已完成的分片、续传半截
        # 文件。之前"残缺=删了重来"让取消的代价变成整个模型重下。
        if os.path.exists(self.local_path) and os.listdir(self.local_path):
            _log(f"模型目录有残留: {self.local_path}，断点续传")
        _emit_event("started", self.model_id)
        self.thread = threading.Thread(
            target=self._run,
            name=f"download-{self.model_id}",
            daemon=True,
        )
        self.thread.start()

    def cancel(self):
        """请求取消。"""
        self.cancelled.set()
        _emit_event("cancelled", self.model_id)

    def _run(self):
        """实际下载逻辑，在工作线程跑。"""
        try:
            os.makedirs(MODELS_DIR, exist_ok=True)
            os.makedirs(self.local_path, exist_ok=True)

            from huggingface_hub import snapshot_download, HfApi

            # 下载加速:设置页开关开启时走 HF 镜像(直连 huggingface.co
            # 缓慢/受限的网络环境)。endpoint 显式传参,不依赖
            # HF_ENDPOINT 环境变量的 import 时机。
            endpoint = _hf_endpoint()
            if endpoint:
                _log(f"下载加速已开启,走镜像: {endpoint}")

            # 注册本任务的 tracker——JsonlProgress.update() 通过 _trackers_by_model
            # 字典找到对应的 tracker 累加字节。
            # 之前用模块级 globals 会在并发/串行下载时互相串改。
            # 传入 cancelled Event:每 chunk 检查,取消时从进度钩子抛
            # DownloadCancelled 真正中断下载线程。
            tracker = _ProgressTracker(cancelled=self.cancelled)
            with _trackers_lock:
                _trackers_by_model[self.model_id] = tracker

            try:
                # 下载前：用 HfApi 拿所有文件总大小，初始化 tracker
                api = HfApi(endpoint=endpoint)
                info = api.model_info(self.model_id, files_metadata=True)
                total = sum(s.size or 0 for s in info.siblings if s.size)
                tracker.set_total(total)
                _log(f"模型总大小: {self.model_id} = {total} bytes")
            except Exception as e:
                _log(f"获取模型大小失败: {self.model_id} - {e}")
                # 如果拿不到总大小，设 0——进度条不会写（add_bytes 会跳过）
                tracker.set_total(0)

            try:
                # snapshot_download 的 tqdm_class 参数：
                # huggingface_hub 对每个文件调 tqdm_class(total=文件大小)
                # 我们的 JsonlProgress.update(n) 把字节累加到全局计数器，
                # 进度 = _bytes_downloaded / _total_bytes_global（跨文件）。
                # .close() 不写 100%——等 snapshot_download 返回后统一写。
                snapshot_download(
                    repo_id=self.model_id,
                    local_dir=self.local_path,
                    cache_dir=os.path.join(MODELS_DIR, ".cache"),
                    tqdm_class=make_tqdm_class(self.model_id),
                    endpoint=endpoint,  # None = 官方,镜像开关见 _hf_endpoint
                )
                # 注:走到这里 = 下载完整结束。即使取消请求恰好在最后
                # 一个 chunk 之后到达(异常没机会抛),模型也已经下完 —
                # 正常走 completed 流程(写 .complete),别浪费这次下载。
                # 之前这里检查 cancelled 直接 return,导致"取消太晚"的
                # 完整模型不写标记,下次点下载被当残缺目录 rmtree 重下。

                # snapshot_download 返回后统一写 100%（不信任单个文件的 close）
                if tracker.total_bytes > 0:
                    _emit_event("progress", self.model_id,
                                downloaded_bytes=tracker.total_bytes,
                                total_bytes=tracker.total_bytes,
                                pct=1.0)

                # 下载完后验证目录是否真的有内容——snapshot_download 内部
                # 会 catch tqdm 的 __init__ 异常（如 JsonlProgress 缺参数），
                # 然后"安静地"返回（不抛异常），daemon 误以为成功。
                # 用目录大小验证：如果 < 1KB，大概率是失败了。
                final_size = sum(
                    os.path.getsize(os.path.join(dp, f))
                    for dp, _, fns in os.walk(self.local_path)
                    for f in fns
                )
                if final_size < 1024:  # < 1KB = 下载失败
                    _log(f"下载失败: {self.model_id} - 目录为空或过小 ({final_size}B)，"
                         f"可能是 huggingface_hub 内部异常被吞掉")
                    _emit_event("failed", self.model_id,
                                error=f"目录为空或过小 ({final_size}B)，可能模型不存在或网络错误")
                    # 清理空目录
                    import shutil
                    shutil.rmtree(self.local_path, ignore_errors=True)
                    return

                _emit_event("completed", self.model_id,
                            total_bytes=final_size)
                # 创建 .complete 标记文件——下次 start() 看到标记直接跳过
                # （避免每次都校验目录大小）
                try:
                    with open(self.local_path + ".complete", "w") as f:
                        f.write(str(final_size))
                except OSError as e:
                    _log(f"写 .complete 标记失败: {e}")
                _log(f"下载完成: {self.model_id} → {self.local_path}")
            except DownloadCancelled:
                # 用户取消 — cancelled 事件已在 cancel() 里发过,这里
                # 静默清退即可。半截文件留在 local_dir + .cache,下次
                # 下载断点续传,零浪费。
                _log(f"下载已取消(进度钩子中断): {self.model_id}")
                return
            except Exception as e:
                if self.cancelled.is_set():
                    # 取消引发的次生异常(hf 线程池包装/连接中断等),
                    # 一律视为取消,不发 failed(UI 已显示"已取消")。
                    _log(f"下载已取消(次生异常 {type(e).__name__}): {self.model_id}")
                    return
                _log(f"下载失败: {self.model_id} - {e}")
                _log(traceback.format_exc())
                _emit_event("failed", self.model_id, error=str(e))
        except Exception as e:
            _log(f"下载任务崩溃: {self.model_id} - {e}")
            _log(traceback.format_exc())
            _emit_event("failed", self.model_id, error=str(e))
        finally:
            # 注销 tracker，避免字典无限增长
            with _trackers_lock:
                _trackers_by_model.pop(self.model_id, None)


# ── 请求轮询 ────────────────────────────────────────────────────────────
class RequestWatcher:
    """轮询请求文件，触发下载/取消动作。"""

    def __init__(self):
        self.active_downloads: dict[str, DownloadTask] = {}
        self.lock = threading.Lock()
        self._last_mtime = 0.0
        # 取消后旧线程还没退干净时用户又点了下载 → 请求进这里,
        # cleanup_finished 清掉死线程后自动重放。之前这种请求被
        # "已在下载"静默吞掉,UI 没有任何反馈,看起来像下载按钮卡死。
        self._pending_download: str | None = None

    def _read_request(self) -> dict | None:
        """读 request 文件，返回解析后的 dict 或 None。"""
        try:
            mtime = os.path.getmtime(REQUEST_FILE)
        except OSError:
            return None
        if mtime <= self._last_mtime:
            return None
        self._last_mtime = mtime
        try:
            with open(REQUEST_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError) as e:
            _log(f"读 request 失败: {e}")
            return None

    def poll(self):
        """主循环调用一次：检查新请求，分发动作。"""
        req = self._read_request()
        if req is None:
            return
        action = req.get("action", "")
        model_id = req.get("model_id", "")
        if not model_id:
            return
        with self.lock:
            existing = self.active_downloads.get(model_id)
            if action == "download":
                if existing and existing.thread and existing.thread.is_alive():
                    if existing.cancelled.is_set():
                        # 旧线程正在取消退出(进度钩子的异常还没抛完),
                        # 请求排队,cleanup_finished 清掉死线程后重放。
                        self._pending_download = model_id
                        _log(f"旧下载正在取消退出,{model_id} 排队等待重放")
                    else:
                        _log(f"已在下载: {model_id}，忽略新请求")
                    return
                self._start_download(model_id)
            elif action == "cancel":
                if self._pending_download == model_id:
                    self._pending_download = None  # 排队中的重放也一并取消
                if existing:
                    existing.cancel()
                else:
                    _emit_event("cancelled", model_id)
            else:
                _log(f"未知 action: {action}")

    def _start_download(self, model_id: str):
        """创建并启动下载任务。调用方必须已持有 self.lock。"""
        task = DownloadTask(model_id)
        self.active_downloads[model_id] = task
        task.start()

    def cleanup_finished(self):
        """清理已完成/失败的下载任务,重放排队中的下载请求。"""
        with self.lock:
            for model_id, task in list(self.active_downloads.items()):
                if task.thread is None or not task.thread.is_alive():
                    del self.active_downloads[model_id]
                    if self._pending_download == model_id:
                        # 取消退出期间用户点过下载 → 现在旧线程退干净了,
                        # 自动重放(断点续传,已下载的分片不会重下)。
                        self._pending_download = None
                        _log(f"重放下载请求: {model_id}")
                        self._start_download(model_id)


# ── 主循环 ──────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="模型下载守护进程")
    parser.add_argument("--out-dir", default="/tmp/whicc-out",
                        help="进度文件 / 请求文件目录")
    parser.add_argument("--models-dir",
                        default=os.path.expanduser("~/Library/Application Support/whicc/models"),
                        help="模型下载目标目录")
    args = parser.parse_args()

    global OUT_DIR, MODELS_DIR, REQUEST_FILE, PROGRESS_FILE
    OUT_DIR = args.out_dir
    MODELS_DIR = args.models_dir
    REQUEST_FILE = os.path.join(OUT_DIR, "model_download_request.json")
    PROGRESS_FILE = os.path.join(OUT_DIR, "model_download.jsonl")

    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(MODELS_DIR, exist_ok=True)

    # 不要在这里清空旧进度文件——BackendLauncher 已经在启动前清空了，
    # 避免 daemon 重启时误执行上次测试残留的 request。
    # daemon 启动时只读 request 文件（mtime 检测），
    # BackendLauncher 负责清理 request + progress 文件。

    _log(f"启动守护进程 models_dir={MODELS_DIR} request={REQUEST_FILE}")

    watcher = RequestWatcher()
    try:
        while True:
            watcher.poll()
            watcher.cleanup_finished()
            time.sleep(1.0)  # 1 秒轮询一次
    except KeyboardInterrupt:
        _log("收到 SIGINT，退出")
    except Exception as e:
        _log(f"主循环异常: {e}")
        _log(traceback.format_exc())
        sys.exit(1)


if __name__ == "__main__":
    main()
