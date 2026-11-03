import Darwin
import XCTest
@testable import NoBeachballsCore

final class SystemSamplerTests: XCTestCase {
    func testSamplingDoesNotAccumulateHostPortReferences() {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        func references() -> mach_port_urefs_t {
            var count: mach_port_urefs_t = 0
            XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &count), KERN_SUCCESS)
            return count
        }

        let before = references()
        do {
            let sampler = SystemSampler()
            let initialized = references()
            for _ in 0..<20 { _ = sampler.sample() }
            XCTAssertEqual(references(), initialized, "Each tick must reuse the sampler's host port")
        }
        XCTAssertEqual(references(), before, "Destroying the sampler must release its host port")
    }
}
