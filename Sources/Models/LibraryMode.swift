import Foundation

// MARK: - MainMode

/// 메인 에디터 영역의 모드. reader = 파일 리더, library = 폴더 라이브러리 뷰.
enum MainMode: String, Codable, CaseIterable {
    case reader
    case library
}

// MARK: - LibraryLayout

/// 라이브러리 뷰 레이아웃. grid = 격자, list = 목록.
enum LibraryLayout: String, Codable, CaseIterable {
    case grid
    case list
}
