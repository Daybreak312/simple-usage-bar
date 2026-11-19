#!/usr/bin/env swift
// LiteLLM 단가표에서 Claude 항목만 추려 Sources/UsageBar/BundledPrices.swift를 만든다.
//
//   swift scripts/update-bundled-prices.swift                 # 원격에서 받아 생성
//   swift scripts/update-bundled-prices.swift <litellm.json>  # 내려받아 둔 사본으로 생성
//
// 추리는 규칙은 앱의 ModelPriceTable.claudeSubset과 같다(키 `claude-…`/`anthropic/claude-…`,
// input/output 단가가 있는 항목, 아래 필드만). 테스트가 번들 사본이 그 규칙의 고정점인지
// (다시 추려도 같은지) 확인하므로, 규칙을 바꾸면 양쪽을 함께 고친다.
import Foundation

let sourceURL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
let keptFields = [
    "input_cost_per_token", "output_cost_per_token",
    "cache_creation_input_token_cost", "cache_creation_input_token_cost_above_1hr",
    "cache_read_input_token_cost", "search_context_cost_per_query", "provider_specific_entry",
]

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("update-bundled-prices: \(msg)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
let raw: Data
var fetched = Date()
if args.count > 1 {
    // 내려받아 둔 사본이면 받은 날짜 = 그 파일의 수정 시각.
    if let m = (try? FileManager.default.attributesOfItem(atPath: args[1]))?[.modificationDate] as? Date { fetched = m }
    guard let d = FileManager.default.contents(atPath: args[1]) else { fail("읽을 수 없음: \(args[1])") }
    raw = d
} else {
    guard let d = try? Data(contentsOf: URL(string: sourceURL)!) else { fail("다운로드 실패: \(sourceURL)") }
    raw = d
}

guard let table = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
    fail("JSON 객체가 아님")
}
func isPrice(_ v: Any?) -> Bool {
    guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return false }
    return n.doubleValue.isFinite && n.doubleValue >= 0
}
var subset: [String: Any] = [:]
for (name, value) in table where name.hasPrefix("claude-") || name.hasPrefix("anthropic/claude-") {
    guard let e = value as? [String: Any],
          isPrice(e["input_cost_per_token"]), isPrice(e["output_cost_per_token"]) else { continue }
    subset[name] = e.filter { keptFields.contains($0.key) }
}
guard !subset.isEmpty else { fail("Claude 항목이 없음") }
guard let json = try? JSONSerialization.data(withJSONObject: subset, options: [.sortedKeys]),
      let text = String(data: json, encoding: .utf8) else { fail("직렬화 실패") }
guard !text.contains("\"#") else { fail("원시 문자열 구분자와 겹치는 내용") }

let day: String = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Seoul")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: fetched)
}()

let out = """
// 자동 생성 파일 — 직접 고치지 말 것. scripts/update-bundled-prices.swift로 다시 만든다.
// 출처: \(sourceURL)
// 받은 날짜: \(day) (Asia/Seoul) · Claude 항목 \(subset.count)개

/// LiteLLM 단가표의 Claude 부분 사본 — 원격 갱신(`ModelPriceSource`)이 한 번도
/// 성공하지 않았거나 캐시가 깨졌을 때 쓰는 마지막 폴백.
enum BundledPrices {
    static let sourceURL = "\(sourceURL)"
    static let fetchedOn = "\(day)"
    static let json = #"\(text)"#
}

"""
let target = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/UsageBar/BundledPrices.swift")
do {
    try out.write(to: target, atomically: true, encoding: .utf8)
    print("생성: \(target.path) (Claude 항목 \(subset.count)개)")
} catch {
    fail("쓰기 실패: \(error.localizedDescription)")
}
