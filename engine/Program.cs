// EasyUtau 엔진: 앱과 표준 입출력으로 한 줄에 JSON 하나씩 주고받는다.
//   앱 → 엔진: {"id": 1, "cmd": "open", "path": "..."}
//   엔진 → 앱: {"id": 1, "ok": true, ...} 또는 {"id": 1, "ok": false, "error": "..."}
//   엔진 → 앱 (알림): {"event": "playpos", "tick": 1920, "playing": true} 등
// OpenUtau는 화면 스레드 하나에서 문서를 고친다고 여긴다: 여기서는 Main 스레드가 그 역할이고(MainLoop),
// 앱이 보낸 명령도 OpenUtau가 뒤에서 넘기는 일도 모두 그 줄에 서서 차례로 돈다.
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using OpenUtau.Audio;
using OpenUtau.Classic;
using OpenUtau.Core;
using Serilog;
using Serilog.Core;
using Serilog.Events;

namespace EasyUtau.Engine {
    /// <summary>Main 스레드에서 차례로 도는 일 줄. OpenUtau의 MainScheduler · PostOnUIThread가 여기로 온다.</summary>
    sealed class MainLoop : TaskScheduler {
        readonly BlockingCollection<Action> queue = new BlockingCollection<Action>();
        Thread thread;

        public void Post(Action action) => queue.Add(action);

        protected override void QueueTask(Task task) => queue.Add(() => TryExecuteTask(task));

        protected override bool TryExecuteTaskInline(Task task, bool taskWasPreviouslyQueued)
            => Thread.CurrentThread == thread && !taskWasPreviouslyQueued && TryExecuteTask(task);

        protected override IEnumerable<Task> GetScheduledTasks() => Array.Empty<Task>();

        public override int MaximumConcurrencyLevel => 1;

        /// <summary>일이 없을 때는 tick마다 idle을 부른다 (재생 위치 알리기 등). 끝날 때까지 돌아오지 않는다.</summary>
        public void Run(Action idle, int tickMs) {
            thread = Thread.CurrentThread;
            var last = DateTime.UtcNow;
            while (true) {
                if (queue.TryTake(out var action, tickMs)) {
                    try {
                        action();
                    } catch (Exception e) {
                        Log.Error(e, "main loop");
                        Protocol.Event("error", new JsonObject { ["message"] = Protocol.Describe(e) });
                    }
                }
                if ((DateTime.UtcNow - last).TotalMilliseconds >= tickMs) {
                    last = DateTime.UtcNow;
                    try {
                        idle();
                    } catch (Exception e) {
                        Log.Warning(e, "idle");
                    }
                }
            }
        }
    }

    /// <summary>OpenUtau 기록은 표준 오류로 (표준 출력은 앱과 주고받는 줄만).</summary>
    sealed class StderrSink : ILogEventSink {
        public void Emit(LogEvent e) {
            var text = $"{e.Timestamp:HH:mm:ss.fff} [{e.Level.ToString().Substring(0, 3)}] {e.RenderMessage()}";
            if (e.Exception != null) {
                text += "\n" + e.Exception;
            }
            Protocol.Stderr(text);
        }
    }

    static class Protocol {
        static TextWriter stdout;
        static TextWriter stderr;
        static readonly object writeLock = new object();

        public static void Init() {
            stdout = new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            stderr = new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
            // OpenUtau 안쪽에서 Console.WriteLine을 해도 주고받는 줄이 섞이지 않게
            Console.SetOut(stderr);
        }

        public static void Write(JsonObject obj) {
            var line = obj.ToJsonString();
            lock (writeLock) {
                stdout.WriteLine(line);
            }
        }

        public static void Stderr(string text) {
            lock (writeLock) {
                stderr.WriteLine(text);
            }
        }

        public static void Event(string name, JsonObject body = null) {
            body ??= new JsonObject();
            body["event"] = name;
            Write(body);
        }

        public static string Describe(Exception e) {
            while ((e is TargetInvocationException || e is AggregateException) && e.InnerException != null) {
                e = e.InnerException;
            }
            return e.Message;
        }
    }

    static class Program {
        public static MainLoop Loop { get; private set; }

        static int Main(string[] args) {
            Protocol.Init();
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            Log.Logger = new LoggerConfiguration()
                .MinimumLevel.Information()
                .WriteTo.Sink(new StderrSink())
                .CreateLogger();
            Loop = new MainLoop();
            var thread = Thread.CurrentThread;
            try {
                UseOwnCache();
                Log.Information($"OpenUtau.Core {typeof(DocManager).Assembly.GetName().Version}, data {PathManager.Inst.DataPath}");
                ToolsManager.Inst.Initialize();
                DocManager.Inst.Initialize(thread, Loop);
                DocManager.Inst.PostOnUIThread = Loop.Post;
                SingerManager.Inst.Initialize();
            } catch (Exception e) {
                Log.Fatal(e, "init");
                Protocol.Event("fatal", new JsonObject { ["message"] = "OpenUtau를 준비하지 못했어요: " + Protocol.Describe(e) });
                return 1;
            }
            var session = new Session();
            session.Start(InitAudio());
            WatchParent();
            var reader = new Thread(() => ReadCommands(session)) { IsBackground = true, Name = "stdin" };
            reader.Start();
            Loop.Run(session.Idle, 30);
            return 0;
        }

        /// <summary>렌더 캐시는 EasyUtau 전용 폴더로: OpenUtau가 같이 켜져 있어도 서로의 캐시를 지우지 않게.</summary>
        static void UseOwnCache() {
            var cache = Environment.GetEnvironmentVariable("EASYUTAU_CACHE");
            if (string.IsNullOrEmpty(cache)) {
                return;
            }
            try {
                Directory.CreateDirectory(cache);
                var prop = typeof(PathManager).GetProperty("CachePath", BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance);
                prop.GetSetMethod(true).Invoke(PathManager.Inst, new object[] { cache });
            } catch (Exception e) {
                Log.Warning(e, "cache path");
            }
        }

        /// <summary>OpenUtau처럼 MiniAudio로 소리를 낸다. 소리 장치가 없으면(CI 등) 소리 없이 둔다.</summary>
        static string InitAudio() {
            if (Environment.GetEnvironmentVariable("EASYUTAU_NO_AUDIO") == "1") {
                return "소리 장치를 쓰지 않아요";
            }
            try {
                PlaybackManager.Inst.AudioOutput = new MiniAudioOutput();
                return null;
            } catch (Exception e) {
                Log.Warning(e, "audio");
                return "소리 장치를 열지 못했어요: " + Protocol.Describe(e);
            }
        }

        static void ReadCommands(Session session) {
            var stdin = new StreamReader(Console.OpenStandardInput(), new UTF8Encoding(false));
            string line;
            while ((line = stdin.ReadLine()) != null) {
                if (string.IsNullOrWhiteSpace(line)) {
                    continue;
                }
                JsonObject request;
                try {
                    request = JsonNode.Parse(line) as JsonObject;
                } catch (Exception e) {
                    Protocol.Event("error", new JsonObject { ["message"] = "명령을 읽지 못했어요: " + e.Message });
                    continue;
                }
                if (request == null) {
                    continue;
                }
                Loop.Post(() => session.Handle(request));
            }
            // 앱이 꺼졌다 (입력이 닫힘)
            Loop.Post(() => {
                session.Shutdown();
                Environment.Exit(0);
            });
        }

        /// <summary>앱이 강제로 꺼져서 입력이 닫히지 않을 때도 혼자 남지 않게.</summary>
        static void WatchParent() {
            var text = Environment.GetEnvironmentVariable("EASYUTAU_PARENT_PID");
            if (!int.TryParse(text, out var pid) || pid <= 0) {
                return;
            }
            new Thread(() => {
                while (true) {
                    Thread.Sleep(1000);
                    try {
                        var p = System.Diagnostics.Process.GetProcessById(pid);
                        if (p.HasExited) {
                            Environment.Exit(0);
                        }
                    } catch (ArgumentException) {
                        Environment.Exit(0);
                    } catch (InvalidOperationException) {
                        Environment.Exit(0);
                    }
                }
            }) { IsBackground = true, Name = "parent" }.Start();
        }
    }
}
