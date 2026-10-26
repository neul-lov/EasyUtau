// 앱이 보낸 명령을 OpenUtau 명령으로 바꿔 돌린다. 고치는 일은 모두 OpenUtau의 되돌리기 묶음(undo group) 하나씩이라
// 앱의 ⌘Z는 엔진의 Undo를 부른다 (메인 화면 · 편집 화면이 같은 되돌리기 줄을 쓴다).
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using OpenUtau.Api;
using OpenUtau.Core;
using OpenUtau.Core.Format;
using OpenUtau.Core.Render;
using OpenUtau.Core.Ustx;
using OpenUtau.Core.Util;
using Serilog;

namespace EasyUtau.Engine {
    sealed class Session : ICmdSubscriber {
        const string Version = "1";

        // 저장한 뒤로 고친 적이 있는지: 고칠 때마다 1씩, 저장하면 그때 값을 기억
        long generation;
        long savedGeneration;
        public bool Saved => generation == savedGeneration;

        int lastTick = -1;
        bool wasPlaying;
        bool waiting;
        readonly HashSet<UVoicePart> phonemized = new HashSet<UVoicePart>();
        DateTime lastProgress = DateTime.MinValue;
        // 내보내는 동안 OpenUtau가 알린 오류 (내보내기는 오류를 던지지 않고 알리기만 한다)
        List<string> exportErrors;
        string audioWarning;

        UProject Project => DocManager.Inst.Project;

        public void Start(string audioWarning) {
            this.audioWarning = audioWarning;
            DocManager.Inst.AddSubscriber(this);
            var project = NewProject(null);
            DocManager.Inst.ExecuteCmd(new LoadProjectNotification(project));
            generation = savedGeneration = 0;
            Protocol.Event("ready", new JsonObject {
                ["version"] = Version,
                ["openutau"] = typeof(DocManager).Assembly.GetName().Version?.ToString() ?? "",
                ["dataPath"] = PathManager.Inst.DataPath,
                ["audio"] = audioWarning == null,
                ["audioWarning"] = audioWarning ?? "",
                ["defaults"] = Defaults(),
            });
        }

        public void Shutdown() {
            try {
                PlaybackManager.Inst.StopPlayback();
            } catch (Exception) { }
        }

        static JsonObject Defaults() {
            var d = NotePresets.Default;
            return new JsonObject {
                ["lyric"] = d.DefaultLyric ?? "a",
                ["portamentoStart"] = d.DefaultPortamento.PortamentoStart,
                ["portamentoLength"] = d.DefaultPortamento.PortamentoLength,
                ["pitchShape"] = d.DefaultPitchShape.ToString(),
                ["vibratoLength"] = d.DefaultVibrato.VibratoLength,
                ["vibratoPeriod"] = d.DefaultVibrato.VibratoPeriod,
                ["vibratoDepth"] = d.DefaultVibrato.VibratoDepth,
                ["vibratoIn"] = d.DefaultVibrato.VibratoIn,
                ["vibratoOut"] = d.DefaultVibrato.VibratoOut,
            };
        }

        // MARK: 알림 받기

        public void OnNext(UCommand cmd, bool isUndo) {
            switch (cmd) {
                case SetPlayPosTickNotification pos:
                    waiting = pos.waitingRendering;
                    break;
                case PhonemizedNotification p:
                    if (p.part != null) {
                        phonemized.Add(p.part);
                    }
                    break;
                case ErrorMessageNotification err:
                    var message = err.e != null ? Protocol.Describe(err.e) : err.message;
                    if (err.e is MessageCustomizableException mce && mce.InnerException != null) {
                        message = Protocol.Describe(mce.InnerException);
                    }
                    if (exportErrors != null) {
                        exportErrors.Add(message);
                    }
                    Protocol.Event("error", new JsonObject { ["message"] = message });
                    break;
                case ProgressBarNotification progress:
                    // 렌더 진행: 너무 자주 보내지 않게
                    if ((DateTime.UtcNow - lastProgress).TotalMilliseconds > 150 || progress.Progress <= 0 || progress.Progress >= 100) {
                        lastProgress = DateTime.UtcNow;
                        Protocol.Event("progress", new JsonObject { ["value"] = progress.Progress, ["info"] = progress.Info ?? "" });
                    }
                    break;
            }
        }

        /// <summary>일이 없을 때마다 (30ms): 재생 위치 · 음소가 새로 나온 파트를 알린다.</summary>
        public void Idle() {
            var pm = PlaybackManager.Inst;
            bool playing = pm.PlayingMaster;
            if (playing) {
                pm.UpdatePlayPos();
                playing = pm.PlayingMaster;
            }
            int tick = DocManager.Inst.playPosTick;
            if (playing != wasPlaying || (playing && tick != lastTick)) {
                Protocol.Event("playpos", new JsonObject { ["tick"] = tick, ["playing"] = playing, ["waiting"] = playing && waiting });
                lastTick = tick;
                wasPlaying = playing;
            }
            if (phonemized.Count > 0 && Project != null) {
                foreach (var part in phonemized) {
                    int index = Project.parts.IndexOf(part);
                    if (index >= 0) {
                        Protocol.Event("phonemized", new JsonObject { ["part"] = index, ["phonemes"] = Json.Phonemes(part) });
                    }
                }
                phonemized.Clear();
            }
        }

        // MARK: 명령

        public void Handle(JsonObject req) {
            var id = req["id"]?.DeepClone();
            var cmd = (string)req["cmd"] ?? "";
            JsonObject reply;
            try {
                reply = Run(cmd, req) ?? new JsonObject();
                reply["ok"] = true;
            } catch (Exception e) {
                Log.Warning(e, cmd);
                if (DocManager.Inst.HasOpenUndoGroup) {
                    DocManager.Inst.RollBackUndoGroup();
                    DocManager.Inst.EndUndoGroup();
                }
                reply = new JsonObject { ["ok"] = false, ["error"] = Protocol.Describe(e) };
            }
            if (reply.ContainsKey("_async")) {
                return;  // 나중에 Reply로 답한다
            }
            reply["id"] = id;
            Protocol.Write(reply);
        }

        static void Reply(JsonNode id, JsonObject reply) {
            reply["id"] = id?.DeepClone();
            Protocol.Write(reply);
        }

        JsonObject Run(string cmd, JsonObject req) {
            switch (cmd) {
                case "hello":
                    return new JsonObject {
                        ["version"] = Version,
                        ["openutau"] = typeof(DocManager).Assembly.GetName().Version?.ToString() ?? "",
                        ["audio"] = audioWarning == null,
                        ["audioWarning"] = audioWarning ?? "",
                        ["defaults"] = Defaults(),
                    };
                case "singers":
                    return new JsonObject { ["singers"] = Singers() };
                case "refreshSingers":
                    SingerManager.Inst.SearchAllSingers();
                    DocManager.Inst.ExecuteCmd(new SingersRefreshedNotification());
                    return new JsonObject { ["singers"] = Singers(), ["project"] = ProjectJson() };
                case "phonemizers":
                    return new JsonObject {
                        ["phonemizers"] = Json.Array(PhonemizerFactory.GetAll(), f => new JsonObject {
                            ["type"] = f.type.FullName, ["name"] = f.name, ["tag"] = f.tag,
                            ["language"] = f.language ?? "", ["author"] = f.author ?? "",
                        }),
                    };
                case "renderers": {
                    var track = TrackAt(req);
                    var type = track.Singer != null && track.Singer.Found ? track.Singer.SingerType : USingerType.Classic;
                    return new JsonObject {
                        ["renderers"] = Json.Array(Renderers.GetSupportedRenderers(type), r => (JsonNode)JsonValue.Create(r)),
                    };
                }
                case "new":
                    Load(NewProject(Str(req, "singer")));
                    return ProjectJson();
                case "open":
                    return Open(Str(req, "path"));
                case "save":
                    Save(Str(req, "path"));
                    return ProjectJson();
                case "project":
                    return ProjectJson();
                case "part":
                    return new JsonObject { ["part"] = Json.Part(Project, PartIndex(req)) };
                case "setPart":
                    return SetPart(req);
                case "undo":
                    Stop();
                    DocManager.Inst.Undo();
                    generation++;
                    return ProjectJson();
                case "redo":
                    Stop();
                    DocManager.Inst.Redo();
                    generation++;
                    return ProjectJson();
                case "addTrack":
                    return AddTrack(req);
                case "removeTrack": {
                    var track = TrackAt(req);
                    Edit("command.track.remove", () => DocManager.Inst.ExecuteCmd(new RemoveTrackCommand(Project, track)));
                    return ProjectJson();
                }
                case "setTrack":
                    return SetTrack(req);
                case "addPart": {
                    var track = TrackAt(req);
                    var part = new UVoicePart {
                        trackNo = track.TrackNo,
                        position = Math.Max(0, Int(req, "position", 0)),
                        Duration = Math.Max(480, Int(req, "duration", 480 * 4 * 8)),
                        name = Str(req, "name") ?? "노래",
                    };
                    Edit("command.part.add", () => DocManager.Inst.ExecuteCmd(new AddPartCommand(Project, part)));
                    var result = ProjectJson();
                    result["added"] = Project.parts.IndexOf(part);
                    return result;
                }
                case "removePart": {
                    var part = Project.parts[PartIndex(req)];
                    Edit("command.part.remove", () => DocManager.Inst.ExecuteCmd(new RemovePartCommand(Project, part)));
                    return ProjectJson();
                }
                case "movePart": {
                    var part = Project.parts[PartIndex(req)];
                    int track = Math.Clamp(Int(req, "track", part.trackNo), 0, Project.tracks.Count - 1);
                    int position = Math.Max(0, Int(req, "position", part.position));
                    if (track != part.trackNo || position != part.position) {
                        Edit("command.part.edit", () => DocManager.Inst.ExecuteCmd(new MovePartCommand(Project, part, position, track)));
                    }
                    return ProjectJson();
                }
                case "resizePart": {
                    if (Project.parts[PartIndex(req)] is UVoicePart part) {
                        int duration = Math.Max(part.GetMinDurTick(Project), Int(req, "duration", part.Duration));
                        if (duration != part.Duration) {
                            Edit("command.part.edit", () => DocManager.Inst.ExecuteCmd(new ResizeVoicePartCommand(Project, part, duration - part.Duration, false)));
                        }
                    }
                    return ProjectJson();
                }
                case "renamePart": {
                    var part = Project.parts[PartIndex(req)];
                    var name = (Str(req, "name") ?? "").Trim();
                    if (name.Length > 0 && name != part.name) {
                        Edit("command.part.rename", () => DocManager.Inst.ExecuteCmd(new RenamePartCommand(Project, part, name)));
                    }
                    return ProjectJson();
                }
                case "duplicatePart": {
                    var part = Project.parts[PartIndex(req)];
                    var copy = part.Clone();
                    copy.position = part.End;
                    if (copy is UVoicePart) {
                        // 새 파트로 (같은 Id면 렌더 캐시가 섞인다)
                        copy = new UVoicePart {
                            name = part.name, trackNo = part.trackNo, position = part.End, Duration = part.Duration,
                            notes = new SortedSet<UNote>(((UVoicePart)part).notes.Select(n => n.Clone())),
                            curves = ((UVoicePart)part).curves.Select(c => c.Clone()).ToList(),
                        };
                    }
                    Edit("command.part.add", () => DocManager.Inst.ExecuteCmd(new AddPartCommand(Project, copy)));
                    var result = ProjectJson();
                    result["added"] = Project.parts.IndexOf(copy);
                    return result;
                }
                case "addWave":
                    return AddWave(req);
                case "setTempo": {
                    double bpm = Math.Clamp(Num(req, "bpm", 120), 10, 1000);
                    if (Math.Abs(bpm - Project.tempos[0].bpm) > 1e-6) {
                        Edit("command.project.tempo", () => DocManager.Inst.ExecuteCmd(new BpmCommand(Project, bpm)));
                    }
                    return ProjectJson();
                }
                case "setTimeSignature": {
                    int beats = Math.Clamp(Int(req, "beatPerBar", 4), 1, 32);
                    int unit = Int(req, "beatUnit", 4);
                    if (unit != 2 && unit != 4 && unit != 8 && unit != 16) {
                        unit = 4;
                    }
                    Edit("command.project.timesig", () => DocManager.Inst.ExecuteCmd(new TimeSignatureCommand(Project, beats, unit)));
                    return ProjectJson();
                }
                case "play": {
                    Stop();
                    DocManager.Inst.FlushValidation();
                    int tick = Math.Max(0, Int(req, "tick", 0));
                    if (Project.EndTick <= tick) {
                        throw new InvalidOperationException("여기서부터는 부를 음표가 없어요");
                    }
                    // 방금 고친 음표의 발음이 아직 안 나왔으면 나올 때까지 기다렸다가 (안 그러면 고치기 전 소리가 난다)
                    var id = req["id"]?.DeepClone();
                    WhenPhonemized(() => {
                        try {
                            DocManager.Inst.ExecuteCmd(new SetPlayPosTickNotification(tick));
                            PlaybackManager.Inst.Play(Project, tick);
                            Reply(id, new JsonObject { ["ok"] = true, ["tick"] = tick });
                        } catch (Exception e) {
                            Reply(id, new JsonObject { ["ok"] = false, ["error"] = Protocol.Describe(e) });
                        }
                    });
                    return new JsonObject { ["_async"] = true };
                }
                case "stop":
                    Stop();
                    return new JsonObject();
                case "otos":
                    return Otos(req);
                case "export":
                    return Export(req);
                default:
                    throw new InvalidOperationException("모르는 명령이에요: " + cmd);
            }
        }

        // MARK: 도우미

        static string Str(JsonObject req, string key) => req[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

        static double Num(JsonObject req, string key, double fallback) {
            if (req[key] is JsonValue v) {
                if (v.TryGetValue<double>(out var d)) return d;
                if (v.TryGetValue<int>(out var i)) return i;
                if (v.TryGetValue<long>(out var l)) return l;
            }
            return fallback;
        }

        static int Int(JsonObject req, string key, int fallback) => (int)Math.Round(Num(req, key, fallback));

        static bool? Bool(JsonObject req, string key) => req[key] is JsonValue v && v.TryGetValue<bool>(out var b) ? b : null;

        int PartIndex(JsonObject req) {
            int index = Int(req, "part", -1);
            if (index < 0 || index >= Project.parts.Count) {
                throw new InvalidOperationException("그 파트를 찾지 못했어요");
            }
            return index;
        }

        UTrack TrackAt(JsonObject req) {
            int index = Int(req, "track", -1);
            if (index < 0 || index >= Project.tracks.Count) {
                throw new InvalidOperationException("그 트랙을 찾지 못했어요");
            }
            return Project.tracks[index];
        }

        JsonObject ProjectJson() => new JsonObject { ["project"] = Json.Project(Project, this) };

        /// <summary>고치는 일 하나 = 되돌리기 묶음 하나.</summary>
        void Edit(string name, Action action) {
            DocManager.Inst.StartUndoGroup(name);
            try {
                action();
            } catch {
                DocManager.Inst.RollBackUndoGroup();
                DocManager.Inst.EndUndoGroup();
                throw;
            }
            DocManager.Inst.EndUndoGroup();
            generation++;
        }

        void Stop() {
            if (PlaybackManager.Inst.PlayingMaster || PlaybackManager.Inst.StartingToPlay) {
                PlaybackManager.Inst.StopPlayback();
            }
        }

        JsonArray Singers() {
            var singers = SingerManager.Inst.Singers.Values
                .Where(s => s.Found)
                .OrderBy(s => s.SingerType)
                .ThenBy(s => s.LocalizedName, StringComparer.CurrentCulture)
                .ToList();
            // OpenUtau에서 최근에 쓴 가수가 먼저
            var recent = Preferences.Default.RecentSingers ?? new List<string>();
            singers = singers.OrderBy(s => {
                int i = recent.IndexOf(s.Id);
                return i < 0 ? int.MaxValue : i;
            }).ToList();
            return Json.Array(singers, s => Json.Singer(s));
        }

        static USinger PickSinger(string id) {
            var singers = SingerManager.Inst.Singers;
            if (!string.IsNullOrEmpty(id) && singers.TryGetValue(id, out var chosen) && chosen.Found) {
                return chosen;
            }
            foreach (var recent in Preferences.Default.RecentSingers ?? new List<string>()) {
                if (singers.TryGetValue(recent, out var s) && s.Found) {
                    return s;
                }
            }
            return singers.Values.Where(s => s.Found).OrderBy(s => s.SingerType).FirstOrDefault();
        }

        /// <summary>가수를 트랙에 넣는다: 발음 방식 · 렌더러도 OpenUtau가 고르는 것처럼 (TrackHeaderViewModel.ApplySingerToTrack).</summary>
        void ApplySinger(UTrack track, USinger singer, bool asCommand) {
            Phonemizer phonemizer = null;
            if (!string.IsNullOrEmpty(singer.Id) && Preferences.Default.SingerPhonemizers != null
                && Preferences.Default.SingerPhonemizers.TryGetValue(singer.Id, out var name)) {
                phonemizer = TryPhonemizer(name);
            }
            if (phonemizer == null && !string.IsNullOrEmpty(singer.DefaultPhonemizer)) {
                phonemizer = TryPhonemizer(singer.DefaultPhonemizer);
            }
            var settings = new URenderSettings { renderer = Renderers.GetDefaultRenderer(singer.SingerType) };
            if (asCommand) {
                DocManager.Inst.ExecuteCmd(new TrackChangeSingerCommand(Project, track, singer));
                if (phonemizer != null) {
                    DocManager.Inst.ExecuteCmd(new TrackChangePhonemizerCommand(Project, track, phonemizer));
                }
                if (track.RendererSettings?.Renderer?.SingerType != singer.SingerType) {
                    DocManager.Inst.ExecuteCmd(new TrackChangeRenderSettingCommand(Project, track, settings));
                }
            } else {
                track.Singer = singer;
                if (phonemizer != null) {
                    track.Phonemizer = phonemizer;
                }
                track.RendererSettings = settings;
            }
        }

        static Phonemizer TryPhonemizer(string typeName) {
            try {
                return PhonemizerFactory.Get(typeName)?.Create();
            } catch (Exception e) {
                Log.Warning(e, "phonemizer " + typeName);
                return null;
            }
        }

        UProject NewProject(string singerId) {
            var project = Ustx.Create();
            var track = project.tracks[0];
            track.TrackNo = 0;
            track.TrackName = "노래";
            var singer = PickSinger(singerId);
            if (singer != null) {
                ApplySinger(track, singer, asCommand: false);
            }
            project.parts.Add(new UVoicePart { trackNo = 0, position = 0, Duration = 480 * 4 * 16, name = "노래" });
            project.ValidateFull();
            return project;
        }

        void Load(UProject project) {
            Stop();
            DocManager.Inst.ExecuteCmd(new LoadProjectNotification(project));
            phonemized.Clear();
            generation = savedGeneration = 0;
        }

        JsonObject Open(string path) {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) {
                throw new FileNotFoundException("파일을 찾지 못했어요: " + path);
            }
            Stop();
            var format = Formats.DetectProjectFormat(path);
            UProject project;
            if (format == ProjectFormats.Ustx) {
                project = Ustx.Load(path);
            } else {
                project = Formats.ReadProject(new[] { path });
                if (project == null) {
                    throw new InvalidOperationException("이 파일은 열 수 없어요");
                }
                project.FilePath = "";  // ust · mid 등은 저장할 때 ustx로 새로 고르게
            }
            Load(project);
            if (!string.IsNullOrEmpty(project.FilePath)) {
                savedGeneration = generation;
            } else {
                savedGeneration = -1;
            }
            return ProjectJson();
        }

        /// <summary>OpenUtau와 같은 ustx로 저장. 다 쓴 뒤에 바꿔 끼워서, 저장하다 꺼져도 원래 파일이 깨지지 않는다.</summary>
        void Save(string path) {
            path = string.IsNullOrEmpty(path) ? Project.FilePath : path;
            if (string.IsNullOrEmpty(path)) {
                throw new InvalidOperationException("저장할 곳을 골라 주세요");
            }
            DocManager.Inst.FlushValidation();
            var project = Project;
            string text;
            lock (project) {
                project.ustxVersion = Ustx.kUstxVersion;
                project.FilePath = path;
                project.BeforeSave();
                try {
                    text = Yaml.DefaultSerializer.Serialize(project);
                } finally {
                    project.AfterSave();
                }
            }
            var dir = Path.GetDirectoryName(Path.GetFullPath(path));
            Directory.CreateDirectory(dir);
            var tmp = Path.Combine(dir, "." + Path.GetFileName(path) + ".easyutau-tmp");
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            File.Move(tmp, path, true);
            project.Saved = true;
            savedGeneration = generation;
        }

        JsonObject SetPart(JsonObject req) {
            int index = PartIndex(req);
            if (Project.parts[index] is not UVoicePart old) {
                throw new InvalidOperationException("노래 파트가 아니에요");
            }
            var track = Project.tracks[old.trackNo];
            var part = (UVoicePart)old.Clone();
            if (req["notes"] is JsonArray notes) {
                part.notes = new SortedSet<UNote>(notes.OfType<JsonObject>().Select(j => Json.ToNote(Project, j)));
            }
            if (req["curves"] is JsonArray curves) {
                part.curves = curves.OfType<JsonObject>()
                    .Select(j => Json.ToCurve(Project, track, j))
                    .Where(c => c != null && c.xs.Count > 0)
                    .GroupBy(c => c.abbr).Select(g => g.Last())
                    .ToList();
            }
            foreach (var note in part.notes) {
                note.AfterLoad(Project, track, part);
            }
            // 음표가 파트 끝을 넘으면 파트를 늘린다 (마디 단위로 한 마디 여유)
            int needed = part.GetMinDurTick(Project);
            if (part.notes.Count > 0) {
                Project.timeAxis.TickPosToBarBeat(part.position + part.notes.Max(n => n.End), out int bar, out _, out _);
                needed = Math.Max(needed, Project.timeAxis.BarBeatToTickPos(bar + 2, 0) - part.position);
            }
            part.Duration = Math.Max(part.Duration, needed);
            string switched = null;
            Edit(Str(req, "label") ?? "command.note.edit", () => {
                DocManager.Inst.ExecuteCmd(new ReplacePartCommand(Project, old, part));
                switched = KoreanOnJapanese(track, part);
            });
            var result = ProjectJson();
            result["part"] = Json.Part(Project, index);
            if (switched != null) {
                result["notice"] = $"한글 가사라서 발음 방식을 \"{switched}\" (한국어를 일본어 음원으로)로 바꿨어요";
            }
            return result;
        }

        const string KoToJa = "OpenUtau.Plugin.Builtin.KOtoJAPhonemizer";

        /// <summary>일본어 UTAU 음원(테토 등)에 한글 가사를 쓰면 OpenUtau의 "KO to JA" 발음 방식으로 바꾼다
        /// (AutoTuner와 같은 방식). 그대로 두면 음원에 없는 소리라 아무 소리도 안 난다. 바꿨으면 그 이름.</summary>
        string KoreanOnJapanese(UTrack track, UVoicePart part) {
            if (track.Singer is not { Found: true, SingerType: USingerType.Classic } singer
                || !part.notes.Any(n => HasHangul(n.lyric))) {
                return null;
            }
            var current = track.Phonemizer == null ? null : PhonemizerFactory.Get(track.Phonemizer.GetType());
            if (current?.language == "KO" || track.Phonemizer?.GetType().FullName == KoToJa) {
                return null;
            }
            bool japanese = current?.language == "JA"
                || (singer.Otos?.Any(o => o.Alias != null && o.Alias.Any(c => c >= '\u3041' && c <= '\u3096')) ?? false);
            var factory = japanese ? PhonemizerFactory.Get(KoToJa) : null;
            if (factory == null) {
                return null;
            }
            DocManager.Inst.ExecuteCmd(new TrackChangePhonemizerCommand(Project, track, factory.Create()));
            return factory.name;
        }

        static bool HasHangul(string text) => text != null && text.Any(c => c >= '\uAC00' && c <= '\uD7A3');

        JsonObject AddTrack(JsonObject req) {
            var track = new UTrack(Project) { TrackNo = Project.tracks.Count };
            var name = Str(req, "name");
            if (!string.IsNullOrWhiteSpace(name)) {
                track.TrackName = name.Trim();
            }
            var singer = PickSinger(Str(req, "singer"));
            bool withPart = Bool(req, "part") ?? true;
            var part = withPart ? new UVoicePart {
                trackNo = track.TrackNo,
                position = Math.Max(0, Int(req, "position", 0)),
                Duration = 480 * 4 * 16,
                name = track.TrackName,
            } : null;
            Edit("command.track.add", () => {
                DocManager.Inst.ExecuteCmd(new AddTrackCommand(Project, track));
                if (singer != null) {
                    ApplySinger(track, singer, asCommand: true);
                }
                if (part != null) {
                    DocManager.Inst.ExecuteCmd(new AddPartCommand(Project, part));
                }
            });
            var result = ProjectJson();
            result["addedTrack"] = track.TrackNo;
            if (part != null) {
                result["added"] = Project.parts.IndexOf(part);
            }
            return result;
        }

        JsonObject SetTrack(JsonObject req) {
            var track = TrackAt(req);
            var name = Str(req, "name");
            var singerId = Str(req, "singer");
            var phonemizer = Str(req, "phonemizer");
            var renderer = Str(req, "renderer");
            var color = Str(req, "color");
            bool undoable = name != null || singerId != null || phonemizer != null || renderer != null || color != null;
            if (undoable) {
                Edit("command.track.edit", () => {
                    if (name != null && name.Trim().Length > 0 && name.Trim() != track.TrackName) {
                        DocManager.Inst.ExecuteCmd(new RenameTrackCommand(Project, track, name.Trim()));
                    }
                    if (color != null && color != track.TrackColor) {
                        DocManager.Inst.ExecuteCmd(new ChangeTrackColorCommand(Project, track, color));
                    }
                    if (singerId != null) {
                        if (!SingerManager.Inst.Singers.TryGetValue(singerId, out var singer) || !singer.Found) {
                            throw new InvalidOperationException("그 가수를 찾지 못했어요");
                        }
                        ApplySinger(track, singer, asCommand: true);
                    }
                    if (phonemizer != null) {
                        var p = TryPhonemizer(phonemizer) ?? throw new InvalidOperationException("그 발음 방식을 찾지 못했어요");
                        DocManager.Inst.ExecuteCmd(new TrackChangePhonemizerCommand(Project, track, p));
                    }
                    if (renderer != null && renderer != track.RendererSettings?.renderer) {
                        DocManager.Inst.ExecuteCmd(new TrackChangeRenderSettingCommand(Project, track, new URenderSettings { renderer = renderer }));
                    }
                });
            }
            // 음소거 · 혼자 듣기 · 볼륨은 OpenUtau처럼 되돌리기 없이 바로
            var mute = Bool(req, "mute");
            var solo = Bool(req, "solo");
            bool mix = false;
            if (mute != null) { track.Mute = mute.Value; mix = true; }
            if (solo != null) { track.Solo = solo.Value; mix = true; }
            if (req.ContainsKey("volume")) { track.Volume = Math.Clamp(Num(req, "volume", 0), -24, 12); mix = true; }
            if (req.ContainsKey("pan")) { track.Pan = Math.Clamp(Num(req, "pan", 0), -100, 100); mix = true; }
            if (mix) {
                bool anySolo = Project.tracks.Any(t => t.Solo);
                foreach (var t in Project.tracks) {
                    t.Muted = !t.Solo && (t.Mute || anySolo);
                    DocManager.Inst.ExecuteCmd(new VolumeChangeNotification(t.TrackNo, t.Muted ? -24 : t.Volume));
                    DocManager.Inst.ExecuteCmd(new PanChangeNotification(t.TrackNo, t.Pan));
                }
                generation++;
            }
            return ProjectJson();
        }

        JsonObject AddWave(JsonObject req) {
            var path = Str(req, "path");
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) {
                throw new FileNotFoundException("소리 파일을 찾지 못했어요");
            }
            var part = new UWavePart { FilePath = path, position = Math.Max(0, Int(req, "position", 0)) };
            part.Load(Project);
            int trackNo = req.ContainsKey("track") ? Int(req, "track", -1) : -1;
            bool newTrack = trackNo < 0 || trackNo >= Project.tracks.Count;
            var track = newTrack ? new UTrack(Project) { TrackNo = Project.tracks.Count, TrackName = Path.GetFileNameWithoutExtension(path) } : null;
            part.trackNo = newTrack ? track.TrackNo : trackNo;
            Edit("command.import.audio", () => {
                if (newTrack) {
                    DocManager.Inst.ExecuteCmd(new AddTrackCommand(Project, track));
                }
                DocManager.Inst.ExecuteCmd(new AddPartCommand(Project, part));
            });
            var result = ProjectJson();
            result["added"] = Project.parts.IndexOf(part);
            return result;
        }

        JsonObject Otos(JsonObject req) {
            var track = TrackAt(req);
            var singer = track.Singer;
            if (singer == null || !singer.Found) {
                return new JsonObject { ["aliases"] = new JsonArray() };
            }
            singer.EnsureLoaded();
            var query = (Str(req, "query") ?? "").Trim();
            int limit = Math.Clamp(Int(req, "limit", 60), 1, 500);
            var aliases = singer.Otos
                .Select(o => o.Alias)
                .Where(a => !string.IsNullOrEmpty(a) && (query.Length == 0 || a.Contains(query, StringComparison.OrdinalIgnoreCase)))
                .Distinct()
                .OrderBy(a => query.Length > 0 && a.StartsWith(query, StringComparison.OrdinalIgnoreCase) ? 0 : 1)
                .ThenBy(a => a.Length)
                .Take(limit)
                .ToList();
            return new JsonObject { ["aliases"] = Json.Array(aliases, a => (JsonNode)JsonValue.Create(a)) };
        }

        /// <summary>wav로 내보내기 (모든 트랙을 섞어서). 끝나면 답한다.</summary>
        JsonObject Export(JsonObject req) {
            var path = Str(req, "path");
            if (string.IsNullOrEmpty(path)) {
                throw new InvalidOperationException("저장할 곳을 골라 주세요");
            }
            Stop();
            DocManager.Inst.FlushValidation();
            var id = req["id"]?.DeepClone();
            var errors = new List<string>();
            exportErrors = errors;
            if (File.Exists(path)) {
                File.Delete(path);
            }
            WhenPhonemized(() => {
                Task task = PlaybackManager.Inst.RenderMixdown(Project, path);
                task.ContinueWith(t => Program.Loop.Post(() => {
                    exportErrors = null;
                    if (t.IsFaulted) {
                        errors.Add(Protocol.Describe(t.Exception));
                    }
                    bool ok = errors.Count == 0 && File.Exists(path) && new FileInfo(path).Length > 44;
                    Reply(id, ok
                        ? new JsonObject { ["ok"] = true, ["path"] = path }
                        : new JsonObject { ["ok"] = false, ["error"] = errors.Count > 0 ? errors[0] : "내보내지 못했어요" });
                }));
            }, 60);
            return new JsonObject { ["_async"] = true };
        }

        /// <summary>노래 파트의 발음(음소)이 모두 나오면 action을 부른다 (기다리는 동안에도 다른 명령은 돈다).</summary>
        void WhenPhonemized(Action action, double seconds = 20) {
            var until = DateTime.UtcNow.AddSeconds(seconds);
            void Check() {
                DocManager.Inst.FlushValidation();
                bool ready = Project.parts.OfType<UVoicePart>().All(p => p.notes.Count == 0 || p.PhonemesUpToDate);
                if (ready || DateTime.UtcNow > until) {
                    action();
                    return;
                }
                Task.Delay(30).ContinueWith(_ => Program.Loop.Post(Check));
            }
            Check();
        }
    }
}
