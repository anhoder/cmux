import XCTest
@testable import OwlMojoBindingsGeneratorCore

final class OwlMojoBindingsGeneratorTests: XCTestCase {
    func testParserReadsEnumsStructsAndInterfaces() throws {
        let file = try MojoParser.parse(source: sampleMojo)

        XCTAssertEqual(file.module, "content.mojom")
        XCTAssertEqual(file.declarations.count, 3)

        guard case .enumeration(let mouseKind) = file.declarations[0] else {
            return XCTFail("expected enum")
        }
        XCTAssertEqual(mouseKind.name, "OwlFreshMouseKind")
        XCTAssertEqual(mouseKind.cases.map(\.name), ["kDown", "kWheel"])
        XCTAssertEqual(mouseKind.cases.map(\.rawValue), [0, 3])

        guard case .structure(let event) = file.declarations[1] else {
            return XCTFail("expected struct")
        }
        XCTAssertEqual(event.fields.map(\.name), ["kind", "delta_x"])
        XCTAssertEqual(event.fields.map { $0.type.swiftName }, ["OwlFreshMouseKind", "Float"])

        guard case .interface(let host) = file.declarations[2] else {
            return XCTFail("expected interface")
        }
        XCTAssertEqual(host.methods.map(\.name), ["Resize", "SendMouse", "CaptureSurface"])
        XCTAssertEqual(host.methods[0].parameters.map(\.name), ["width", "height", "scale"])
        XCTAssertEqual(host.methods[2].responseParameters.map(\.name), ["result"])
    }

    func testGeneratorEmitsSwiftTypesAndSchemaChecksum() throws {
        let file = try MojoParser.parse(source: sampleMojo)
        let result = MojoSwiftGenerator.generate(file: file, source: sampleMojo)

        XCTAssertTrue(result.swift.contains("public enum OwlFreshMouseKind: UInt32"))
        XCTAssertTrue(result.swift.contains("case down = 0"))
        XCTAssertTrue(result.swift.contains("public struct OwlFreshMouseEvent"))
        XCTAssertTrue(result.swift.contains("public let deltaX: Float"))
        XCTAssertTrue(result.swift.contains("public struct OwlFreshHostResizeRequest"))
        XCTAssertTrue(result.swift.contains("func resize(_ request: OwlFreshHostResizeRequest)"))
        XCTAssertTrue(result.swift.contains("public static let sourceChecksum = \"\(result.checksum)\""))
    }

    func testReportShowsPassStatusAndGeneratedDeclarations() throws {
        let file = try MojoParser.parse(source: sampleMojo)
        let result = MojoSwiftGenerator.generate(file: file, source: sampleMojo)
        let report = BindingsReportRenderer.render(
            file: file,
            result: result,
            status: .passed,
            mojomPath: "Mojo/OwlFresh.mojom",
            swiftPath: "Sources/OwlLayerHostVerifier/OwlFresh.generated.swift"
        )

        XCTAssertTrue(report.contains("PASS"))
        XCTAssertTrue(report.contains("OwlFreshMouseKind"))
        XCTAssertTrue(report.contains(result.checksum))
        XCTAssertTrue(report.contains("protocol OwlFreshHostMojoInterface"))
    }

    private let sampleMojo = """
    module content.mojom;

    enum OwlFreshMouseKind {
      kDown = 0,
      kWheel = 3,
    };

    struct OwlFreshMouseEvent {
      OwlFreshMouseKind kind;
      float delta_x;
    };

    interface OwlFreshHost {
      Resize(uint32 width, uint32 height, float scale);
      SendMouse(OwlFreshMouseEvent event);
      CaptureSurface() => (OwlFreshMouseEvent result);
    };
    """
}
