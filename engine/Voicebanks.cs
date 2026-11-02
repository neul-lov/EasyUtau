// 가수 음원(zip 등)을 OpenUtau 가수 폴더에 넣는다. OpenUtau의 "가수 설치"와 같은 VoicebankInstaller를 쓴다.
// OpenUtau가 없어도 EasyUtau만으로 음원을 넣을 수 있게.
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;

namespace EasyUtau.Engine {
    static class Voicebanks {
        static readonly Encoding StrictUtf8 = new UTF8Encoding(false, true);

        /// <summary>zip 안 파일 이름이 모두 UTF-8 표시(일반 플래그 11번)를 달고 있는지. 아니면 일본 음원처럼 Shift-JIS로 읽는다.</summary>
        public static bool ZipNamesAreUtf8(string path) {
            try {
                using var fs = File.OpenRead(path);
                long len = fs.Length;
                if (len < 22) {
                    return false;
                }
                // 끝에서 중앙 디렉터리 끝 기록(EOCD)을 찾는다 (주석이 있으면 최대 64KB 앞)
                int tail = (int)Math.Min(len, 22 + 65535);
                var buf = new byte[tail];
                fs.Seek(len - tail, SeekOrigin.Begin);
                fs.ReadExactly(buf, 0, tail);
                int eocd = -1;
                for (int i = tail - 22; i >= 0; i--) {
                    if (buf[i] == 0x50 && buf[i + 1] == 0x4b && buf[i + 2] == 0x05 && buf[i + 3] == 0x06) {
                        eocd = i;
                        break;
                    }
                }
                if (eocd < 0) {
                    return false;
                }
                int count = BitConverter.ToUInt16(buf, eocd + 10);
                long size = BitConverter.ToUInt32(buf, eocd + 12);
                long offset = BitConverter.ToUInt32(buf, eocd + 16);
                if (count == 0 || offset + size > len || size > 64 * 1024 * 1024) {
                    return false;  // zip64 등: 안전하게 Shift-JIS
                }
                var cd = new byte[size];
                fs.Seek(offset, SeekOrigin.Begin);
                fs.ReadExactly(cd, 0, (int)size);
                int p = 0;
                for (int n = 0; n < count; n++) {
                    if (p + 46 > cd.Length || BitConverter.ToUInt32(cd, p) != 0x02014b50) {
                        return false;
                    }
                    int flags = BitConverter.ToUInt16(cd, p + 8);
                    int nameLen = BitConverter.ToUInt16(cd, p + 28);
                    int extraLen = BitConverter.ToUInt16(cd, p + 30);
                    int commentLen = BitConverter.ToUInt16(cd, p + 32);
                    // 표시가 없어도 올바른 UTF-8이면 UTF-8로 본다 (Mac에서 만든 zip은 표시 없이 UTF-8로 쓴다.
                    // Shift-JIS 일본어 이름은 거의 언제나 올바른 UTF-8이 아니다). 영문 이름은 어느 쪽이든 같다.
                    if ((flags & 0x800) == 0 && p + 46 + nameLen <= cd.Length) {
                        try {
                            StrictUtf8.GetString(cd, p + 46, nameLen);
                        } catch (DecoderFallbackException) {
                            return false;
                        }
                    }
                    p += 46 + nameLen + extraLen + commentLen;
                }
                return true;
            } catch (Exception) {
                return false;
            }
        }

        /// <summary>음원 종류: diffsinger · enunu · utau (OpenUtau 가수 설치의 선택지와 같다).</summary>
        public static string SingerType(string path) {
            try {
                using var zip = ZipFile.OpenRead(path);
                var names = zip.Entries.Select(e => Path.GetFileName(e.FullName.Replace('\\', '/'))).ToHashSet(StringComparer.OrdinalIgnoreCase);
                if (names.Contains("dsconfig.yaml")) {
                    return "diffsinger";
                }
                if (names.Contains("enuconfig.yaml")) {
                    return "enunu";
                }
            } catch (Exception) {
                // zip이 아니면 (rar · 7z 등) 기본값
            }
            return "utau";
        }

        public static Encoding ShiftJis => Encoding.GetEncoding("shift_jis");
    }
}
