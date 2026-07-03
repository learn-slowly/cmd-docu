import SwiftUI

/// 파일/폴더 정보 시트(⌥⌘I) — 기본 필드 즉시 + 종류별 한 줄·폴더 크기 비동기.
/// 시트가 닫히면 .task가 취소돼 폴더 크기 계산도 중단된다.
struct FileInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let request: FileInfoRequest

    @State private var info: FileInfo?
    @State private var detail: String?
    @State private var folderSizeText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("정보").font(.headline)
            if let info {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("이름", info.name)
                    row("종류", info.kindLabel)
                    row("크기", sizeText(info))
                    row("위치", info.locationPath)
                    row("생성일", formatted(info.createdAt))
                    row("수정일", formatted(info.modifiedAt))
                    // 종류별 한 줄 — 도착 전에도 자리 예약(리플로우 방지, 리스트 셀 summary 관례)
                    row("정보", detail ?? " ")
                }
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: request.url) {
            let basic = FileInfoService.loadBasic(url: request.url)
            info = basic
            detail = await FileInfoService.loadDetail(url: request.url, isDirectory: basic.isDirectory)
            if basic.isDirectory {
                folderSizeText = "계산 중…"
                if let bytes = try? await FileInfoService.computeFolderSize(url: request.url) {
                    folderSizeText = FileInfoService.formatSize(bytes)
                } else {
                    folderSizeText = "--"   // 취소·실패
                }
            }
        }
    }

    private func sizeText(_ info: FileInfo) -> String {
        if info.isDirectory { return folderSizeText ?? "계산 중…" }
        return info.sizeBytes.map(FileInfoService.formatSize) ?? "--"
    }

    private func formatted(_ date: Date?) -> String {
        date?.formatted(.dateTime.year().month().day().hour().minute()) ?? "--"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
