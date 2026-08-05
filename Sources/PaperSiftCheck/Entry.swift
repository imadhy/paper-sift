import Foundation

@main
struct PaperSiftCheck {
    @MainActor
    static func main() async {
        let run = TestRun()
        await run.suite("Tokenizer", TokenizerChecks.cases)
        await run.suite("Store & FTS5", StoreChecks.cases)
        await run.suite("Extraction", ExtractionChecks.cases)
        await run.suite("Indexing pipeline", IndexingChecks.cases)
        await run.suite("Query, ranking & search", SearchChecks.cases)
        await run.suite("OCR", OCRChecks.cases)
        await run.suite("Formats beyond PDF", FormatChecks.cases)
        exit(run.summarize() ? 0 : 1)
    }
}
