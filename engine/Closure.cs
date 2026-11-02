// 엔진이 실제로 쓰는 .NET 어셈블리 목록 (앱에 넣을 OpenUtau 엔진을 가볍게 만들 때 쓴다).
// OpenUtau 프로그램 폴더에는 화면(Avalonia 등)용 파일도 많이 들어 있다. 엔진은 OpenUtau.Core와
// 기본 발음 방식(OpenUtau.Plugin.Builtin)만 쓰므로, 여기서부터 참조를 따라가 닿는 것만 남기면 된다.
// 실행: ./EasyUtauEngine --closure  → 한 줄에 파일 이름 하나 (예: OpenUtau.Core.dll)
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;

namespace EasyUtau.Engine {
    static class Closure {
        // OpenUtau.Core가 이름으로 직접 읽는 것 (참조가 아니라 파일로 찾음): DocManager.SearchAllPlugins
        static readonly string[] Roots = { "EasyUtauEngine", "OpenUtau.Core", "OpenUtau.Plugin.Builtin" };

        public static int Print() {
            var dir = AppContext.BaseDirectory;
            var files = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var f in Directory.GetFiles(dir, "*.dll")) {
                files[Path.GetFileNameWithoutExtension(f)] = f;
            }
            var need = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            var todo = new Stack<string>(Roots);
            var missing = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
            while (todo.Count > 0) {
                var name = todo.Pop();
                if (!files.TryGetValue(name, out var file)) {
                    missing.Add(name);
                    continue;
                }
                if (!need.Add(name)) {
                    continue;
                }
                try {
                    using var stream = File.OpenRead(file);
                    using var pe = new PEReader(stream);
                    if (!pe.HasMetadata) {
                        continue;
                    }
                    var md = pe.GetMetadataReader();
                    foreach (var h in md.AssemblyReferences) {
                        todo.Push(md.GetString(md.GetAssemblyReference(h).Name));
                    }
                } catch (BadImageFormatException) {
                    // 네이티브 파일
                }
            }
            foreach (var n in need) {
                Console.WriteLine(Path.GetFileName(files[n]));
            }
            // 폴더에 없는 참조 (런타임 밖 · 윈도 전용 등): 확인용으로 표준 오류에
            foreach (var m in missing.Where(m => !m.StartsWith("System", StringComparison.OrdinalIgnoreCase)
                                                && !m.StartsWith("Microsoft", StringComparison.OrdinalIgnoreCase)
                                                && m != "mscorlib" && m != "netstandard" && m != "WindowsBase")) {
                Console.Error.WriteLine("없음: " + m);
            }
            return 0;
        }
    }
}
