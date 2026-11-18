import AppKit
import Vision

struct OCRCharacter {
    let text: String
    let rect: CGRect
}

struct OCRLine {
    let text: String
    let rect: CGRect
    let confidence: Float
    let characters: [OCRCharacter]
}

enum TextRecognizer {
    static func recognize(_ image: CGImage, completion: @escaping (Result<[OCRLine], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // 优先输出精确识别；Vision 的 confidence 不能可靠代表整行识别正确率，
                // 不以快速档的平均分数替代精确识别。
                let lines = try recognize(image, level: .accurate)
                DispatchQueue.main.async { completion(.success(lines)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func recognize(_ image: CGImage, level: VNRequestTextRecognitionLevel) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = (level == .accurate)
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.minimumTextHeight = 0.006

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let characters = candidate.string.indices.compactMap { index -> OCRCharacter? in
                guard let next = candidate.string.index(index, offsetBy: 1, limitedBy: candidate.string.endIndex),
                      let box = try? candidate.boundingBox(for: index..<next) else { return nil }
                return OCRCharacter(text: String(candidate.string[index..<next]), rect: box.boundingBox)
            }
            return OCRLine(text: candidate.string,
                           rect: observation.boundingBox,
                           confidence: candidate.confidence,
                           characters: characters)
        }
    }
}
