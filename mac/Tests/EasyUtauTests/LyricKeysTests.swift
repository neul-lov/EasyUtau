import Foundation
import XCTest
@testable import EasyUtau

/// 가사 칸에서 ⌫ · Delete: 글자를 지울지, 섹터를 지울지
final class LyricKeysTests: XCTestCase {
    func all(_ text: String) -> NSRange { NSRange(location: 0, length: (text as NSString).length) }

    func testEmptyBoxDeletesNote() {
        // 글자를 다 지운 칸에서 한 번 더 ⌫ (새 섹터든 원래 있던 섹터든)
        XCTAssertTrue(LyricKeys.deletesNote(text: "", selected: NSRange(location: 0, length: 0),
                                            openedWith: "라", isNew: false, composing: false))
        XCTAssertTrue(LyricKeys.deletesNote(text: "", selected: nil, openedWith: "아", isNew: true, composing: false))
    }

    func testUntouchedNewNoteDeletesAtOnce() {
        // 빈 곳을 잘못 눌러 만든 섹터: 처음 가사가 다 골라진 채로 ⌫
        XCTAssertTrue(LyricKeys.deletesNote(text: "아", selected: all("아"), openedWith: "아", isNew: true, composing: false))
        XCTAssertTrue(LyricKeys.deletesNote(text: "あ", selected: all("あ"), openedWith: "あ", isNew: true, composing: false))
    }

    func testTypingKeepsNote() {
        // 가사를 바꿨거나 커서를 옮겼으면 글자만 지운다
        XCTAssertFalse(LyricKeys.deletesNote(text: "라", selected: NSRange(location: 1, length: 0),
                                             openedWith: "아", isNew: true, composing: false))
        XCTAssertFalse(LyricKeys.deletesNote(text: "아", selected: NSRange(location: 1, length: 0),
                                             openedWith: "아", isNew: true, composing: false))
        XCTAssertFalse(LyricKeys.deletesNote(text: "라", selected: all("라"), openedWith: "아", isNew: true, composing: false))
        // 원래 있던 섹터의 가사를 고치려고 두 번 눌러 연 칸: 첫 ⌫는 글자를 지운다
        XCTAssertFalse(LyricKeys.deletesNote(text: "라", selected: all("라"), openedWith: "라", isNew: false, composing: false))
    }

    func testComposingHangulKeepsNote() {
        // 한글 조합 중의 ⌫는 자모를 지운다
        XCTAssertFalse(LyricKeys.deletesNote(text: "ㄹ", selected: NSRange(location: 1, length: 0),
                                             openedWith: "아", isNew: true, composing: true))
        XCTAssertFalse(LyricKeys.deletesNote(text: "아", selected: all("아"), openedWith: "아", isNew: true, composing: true))
    }
}
