// 프로젝트 ↔ 앱이 읽는 JSON. 앱(EasyUtau/Model.swift)과 이름을 맞춘다.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using OpenUtau.Api;
using OpenUtau.Core;
using OpenUtau.Core.Render;
using OpenUtau.Core.Ustx;

namespace EasyUtau.Engine {
    static class Json {
        public static JsonArray Array<T>(IEnumerable<T> items, Func<T, JsonNode> map) {
            var a = new JsonArray();
            foreach (var item in items) {
                a.Add(map(item));
            }
            return a;
        }

        public static JsonArray Ints(IEnumerable<int> items) => Array(items, i => (JsonNode)JsonValue.Create(i));

        static float F(float v) => float.IsFinite(v) ? v : 0;

        // MARK: 프로젝트

        public static JsonObject Project(UProject project, Session session) {
            var tempos = project.tempos.OrderBy(t => t.position).ToList();
            var sigs = project.timeSignatures.OrderBy(t => t.barPosition).ToList();
            var obj = new JsonObject {
                ["path"] = project.FilePath ?? "",
                ["name"] = string.IsNullOrEmpty(project.FilePath) ? "" : Path.GetFileNameWithoutExtension(project.FilePath),
                ["saved"] = session.Saved,
                ["canUndo"] = DocManager.Inst.GetUndoState(out _),
                ["canRedo"] = DocManager.Inst.GetRedoState(out _),
                ["resolution"] = project.resolution,
                ["key"] = project.key,
                ["endTick"] = project.EndTick,
                ["tempos"] = Array(tempos, t => new JsonObject { ["position"] = t.position, ["bpm"] = t.bpm }),
                ["timeSignatures"] = Array(sigs, s => new JsonObject {
                    ["barPosition"] = s.barPosition, ["beatPerBar"] = s.beatPerBar, ["beatUnit"] = s.beatUnit,
                }),
                ["tracks"] = Array(project.tracks, t => Track(project, t)),
                ["parts"] = Array(Enumerable.Range(0, project.parts.Count), i => PartSummary(project, i)),
            };
            return obj;
        }

        public static JsonObject Track(UProject project, UTrack track) {
            var singer = track.Singer;
            var phonemizer = track.Phonemizer;
            var factory = phonemizer == null ? null : PhonemizerFactory.Get(phonemizer.GetType());
            return new JsonObject {
                ["index"] = track.TrackNo,
                ["name"] = track.TrackName ?? "",
                ["color"] = track.TrackColor ?? "",
                ["singer"] = singer == null ? null : Singer(singer),
                ["phonemizer"] = phonemizer?.GetType().FullName ?? "",
                ["phonemizerName"] = factory == null ? (phonemizer?.Name ?? "") : factory.name,
                ["phonemizerTag"] = factory?.tag ?? "",
                ["phonemizerLanguage"] = factory?.language ?? "",
                ["renderer"] = track.RendererSettings?.renderer ?? "",
                ["resampler"] = track.RendererSettings?.resampler ?? "",
                ["mute"] = track.Mute,
                ["solo"] = track.Solo,
                ["volume"] = track.Volume,
                ["pan"] = track.Pan,
            };
        }

        public static JsonObject Singer(USinger singer) => new JsonObject {
            ["id"] = singer.Id ?? "",
            ["name"] = singer.LocalizedName ?? singer.Name ?? "",
            ["type"] = singer.SingerType.ToString(),
            ["found"] = singer.Found,
            ["loaded"] = singer.Loaded,
            ["avatar"] = singer.Found && !string.IsNullOrEmpty(singer.Avatar) && File.Exists(singer.Avatar) ? singer.Avatar : "",
            ["portrait"] = singer.Found && !string.IsNullOrEmpty(singer.Portrait) && File.Exists(singer.Portrait) ? singer.Portrait : "",
            ["author"] = singer.Found ? (singer.Author ?? "") : "",
            ["web"] = singer.Found ? (singer.Web ?? "") : "",
            ["defaultPhonemizer"] = singer.Found ? (singer.DefaultPhonemizer ?? "") : "",
            ["location"] = singer.Found ? (singer.Location ?? "") : "",
        };

        /// <summary>메인 화면용: 음표는 위치 · 길이 · 높이만 (미리 보기 그림).</summary>
        public static JsonObject PartSummary(UProject project, int index) {
            var part = project.parts[index];
            var obj = new JsonObject {
                ["index"] = index,
                ["track"] = part.trackNo,
                ["position"] = part.position,
                ["duration"] = part.Duration,
                ["name"] = part.DisplayName ?? "",
            };
            if (part is UVoicePart voice) {
                obj["kind"] = "voice";
                obj["notes"] = Array(voice.notes, n => new JsonArray(n.position, n.duration, n.tone));
                obj["lyrics"] = Array(voice.notes.Take(24), n => (JsonNode)JsonValue.Create(n.lyric));
            } else if (part is UWavePart wave) {
                obj["kind"] = "wave";
                obj["file"] = wave.FilePath ?? "";
                obj["missing"] = string.IsNullOrEmpty(wave.FilePath) || !File.Exists(wave.FilePath);
                obj["fileDurationMs"] = wave.fileDurationMs;
            }
            return obj;
        }

        /// <summary>편집 화면용: 음표 전부 · 곡선 · 음소 · 이 트랙에서 쓸 수 있는 표현.</summary>
        public static JsonObject Part(UProject project, int index) {
            var obj = PartSummary(project, index);
            if (project.parts[index] is not UVoicePart part) {
                return obj;
            }
            var track = project.tracks[part.trackNo];
            obj["notes"] = Array(part.notes, n => Note(n));
            obj["curves"] = Array(part.curves.Where(c => c.xs.Count > 0), c => new JsonObject {
                ["abbr"] = c.abbr,
                ["xs"] = Ints(c.xs),
                ["ys"] = Ints(c.ys),
            });
            obj["phonemesReady"] = part.PhonemesUpToDate;
            obj["phonemes"] = Phonemes(part);
            obj["expressions"] = Expressions(project, track);
            return obj;
        }

        public static JsonObject Note(UNote n) => new JsonObject {
            ["position"] = n.position,
            ["duration"] = n.duration,
            ["tone"] = n.tone,
            ["lyric"] = n.lyric ?? "",
            ["tuning"] = n.tuning,
            ["phonemizer"] = n.PhonemizerOverride,
            ["pitch"] = new JsonObject {
                ["snapFirst"] = n.pitch.snapFirst,
                ["data"] = Array(n.pitch.data, p => new JsonObject {
                    ["x"] = F(p.X), ["y"] = F(p.Y), ["shape"] = p.shape.ToString(),
                }),
            },
            ["vibrato"] = new JsonObject {
                ["length"] = n.vibrato.length,
                ["period"] = n.vibrato.period,
                ["depth"] = n.vibrato.depth,
                ["in"] = n.vibrato.@in,
                ["out"] = n.vibrato.@out,
                ["shift"] = n.vibrato.shift,
                ["drift"] = n.vibrato.drift,
                ["volLink"] = n.vibrato.volLink,
            },
            ["exps"] = Array(n.phonemeExpressions, e => new JsonObject {
                ["index"] = e.index ?? 0, ["abbr"] = e.abbr, ["value"] = F(e.value),
            }),
            ["overrides"] = Array(n.phonemeOverrides.Where(o => !o.IsEmpty), o => new JsonObject {
                ["index"] = o.index,
                ["phoneme"] = o.phoneme,
                ["offset"] = o.offset,
                ["preutterDelta"] = o.preutterDelta,
                ["overlapDelta"] = o.overlapDelta,
                ["attackTimeDelta"] = o.attackTimeDelta,
                ["releaseTimeDelta"] = o.releaseTimeDelta,
            }),
        };

        public static JsonArray Phonemes(UVoicePart part) {
            var noteIndex = new Dictionary<UNote, int>();
            int i = 0;
            foreach (var n in part.notes) {
                noteIndex[n] = i++;
            }
            var result = new JsonArray();
            foreach (var p in part.phonemes.ToList()) {
                if (p.Parent == null || !noteIndex.TryGetValue(p.Parent, out var ni)) {
                    continue;
                }
                result.Add(new JsonObject {
                    ["note"] = ni,
                    ["index"] = p.index,
                    ["position"] = p.position,
                    ["duration"] = p.Duration,
                    ["phoneme"] = p.phoneme ?? "",
                    ["error"] = p.Error,
                    ["preutter"] = p.preutter,
                    ["overlap"] = p.overlap,
                    ["oto"] = p.oto?.Alias ?? "",
                });
            }
            return result;
        }

        public static JsonArray Expressions(UProject project, UTrack track) {
            var renderer = track.RendererSettings?.Renderer;
            var seen = new HashSet<string>();
            var result = new JsonArray();
            var abbrs = project.expressions.Keys.Concat(track.TrackExpressions.Select(e => e.abbr)).ToList();
            foreach (var abbr in abbrs) {
                if (!seen.Add(abbr) || !track.TryGetExpDescriptor(project, abbr, out var d)) {
                    continue;
                }
                bool supported;
                try {
                    supported = renderer != null && renderer.SupportsExpression(d);
                } catch (Exception) {
                    supported = false;
                }
                result.Add(new JsonObject {
                    ["abbr"] = d.abbr,
                    ["name"] = d.name ?? d.abbr,
                    ["type"] = d.type.ToString(),
                    ["min"] = F(d.min),
                    ["max"] = F(d.max),
                    ["defaultValue"] = F(d.CustomDefaultValue),
                    ["isFlag"] = d.isFlag,
                    ["flag"] = d.flag ?? "",
                    ["options"] = d.options == null ? new JsonArray() : Array(d.options, o => (JsonNode)JsonValue.Create(o ?? "")),
                    ["supported"] = supported,
                });
            }
            return result;
        }

        // MARK: 앱 → 엔진

        static float Num(JsonNode node, float fallback) {
            if (node == null) {
                return fallback;
            }
            try {
                return node.GetValue<float>();
            } catch (Exception) {
                try {
                    return (float)node.GetValue<double>();
                } catch (Exception) {
                    return fallback;
                }
            }
        }

        static int Int(JsonNode node, int fallback) => (int)Math.Round(Num(node, fallback));

        static float? NumOrNull(JsonNode node) => node == null ? null : Num(node, 0);

        static int? IntOrNull(JsonNode node) => node == null ? null : Int(node, 0);

        /// <summary>앱이 보낸 음표 하나. 피치 점 · 비브라토가 없으면 OpenUtau 기본값(새 음표와 같게).</summary>
        public static UNote ToNote(UProject project, JsonObject j) {
            var n = project.CreateNote();
            n.position = Math.Max(0, Int(j["position"], 0));
            n.duration = Math.Max(10, Int(j["duration"], 480));
            n.tone = Math.Clamp(Int(j["tone"], 60), 0, 127);
            n.lyric = (string)j["lyric"] ?? "a";
            n.tuning = Int(j["tuning"], 0);
            var ph = (string)j["phonemizer"];
            n.PhonemizerOverride = string.IsNullOrEmpty(ph) ? null : ph;
            if (j["pitch"] is JsonObject pitch && pitch["data"] is JsonArray data && data.Count > 0) {
                n.pitch = new UPitch { snapFirst = pitch["snapFirst"]?.GetValue<bool>() ?? true };
                foreach (var p in data.OfType<JsonObject>()) {
                    var shape = PitchPointShape.io;
                    Enum.TryParse((string)p["shape"] ?? "io", out shape);
                    n.pitch.data.Add(new PitchPoint(Num(p["x"], 0), Num(p["y"], 0), shape));
                }
                n.pitch.data.Sort();
            }
            if (j["vibrato"] is JsonObject v) {
                n.vibrato.length = Num(v["length"], n.vibrato.length);
                n.vibrato.period = Num(v["period"], n.vibrato.period);
                n.vibrato.depth = Num(v["depth"], n.vibrato.depth);
                n.vibrato.@in = Num(v["in"], n.vibrato.@in);
                n.vibrato.@out = Num(v["out"], n.vibrato.@out);
                n.vibrato.shift = Num(v["shift"], n.vibrato.shift);
                n.vibrato.drift = Num(v["drift"], n.vibrato.drift);
                n.vibrato.volLink = Num(v["volLink"], n.vibrato.volLink);
            }
            if (j["exps"] is JsonArray exps) {
                foreach (var e in exps.OfType<JsonObject>()) {
                    var abbr = (string)e["abbr"];
                    if (string.IsNullOrEmpty(abbr)) {
                        continue;
                    }
                    n.phonemeExpressions.Add(new UExpression(abbr) { index = Int(e["index"], 0), value = Num(e["value"], 0) });
                }
            }
            if (j["overrides"] is JsonArray overrides) {
                foreach (var o in overrides.OfType<JsonObject>()) {
                    var ov = new UPhonemeOverride {
                        index = Int(o["index"], 0),
                        phoneme = string.IsNullOrWhiteSpace((string)o["phoneme"]) ? null : (string)o["phoneme"],
                        offset = IntOrNull(o["offset"]),
                        preutterDelta = NumOrNull(o["preutterDelta"]),
                        overlapDelta = NumOrNull(o["overlapDelta"]),
                        attackTimeDelta = NumOrNull(o["attackTimeDelta"]),
                        releaseTimeDelta = NumOrNull(o["releaseTimeDelta"]),
                    };
                    if (!ov.IsEmpty) {
                        n.phonemeOverrides.Add(ov);
                    }
                }
            }
            return n;
        }

        public static UCurve ToCurve(UProject project, UTrack track, JsonObject j) {
            var abbr = (string)j["abbr"];
            if (string.IsNullOrEmpty(abbr) || !track.TryGetExpDescriptor(project, abbr, out var d)) {
                return null;
            }
            var xs = (j["xs"] as JsonArray)?.Select(x => Int(x, 0)).ToList() ?? new List<int>();
            var ys = (j["ys"] as JsonArray)?.Select(y => Int(y, 0)).ToList() ?? new List<int>();
            int count = Math.Min(xs.Count, ys.Count);
            var points = Enumerable.Range(0, count).Select(i => (x: xs[i], y: (int)Math.Clamp(ys[i], d.min, d.max)))
                .GroupBy(p => p.x).Select(g => g.Last()).OrderBy(p => p.x).ToList();
            return new UCurve(d) {
                xs = points.Select(p => p.x).ToList(),
                ys = points.Select(p => p.y).ToList(),
            };
        }
    }
}
