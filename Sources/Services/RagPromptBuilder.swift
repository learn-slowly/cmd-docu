import Foundation

/// RAG 답변 지시 프롬프트(순수). 근거만 사용·[n] 인용·근거 없으면 모른다고 답하게 강제.
enum RagPromptBuilder {
    static func prompt(question: String) -> String {
        """
        당신은 사용자의 개인 자료를 근거로만 답하는 조수다.
        아래 stdin으로 주어진 [1], [2] … 근거 안의 내용만 사용해 한국어로 답하라.
        답에 근거를 쓸 때마다 해당 번호를 [1]처럼 붙여라.
        근거에서 답을 찾을 수 없으면 지어내지 말고 "자료에 없습니다"라고만 답하라.

        질문: \(question)
        """
    }
}
