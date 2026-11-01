import Photos
import Synchronization
import UIKit
import XCTest
@testable import ImmichApp

final class PhotoMediaRequestTests: XCTestCase {
    func testImageAdapterWaitsForFinalQualityAndIgnoresDuplicateCompletions() async {
        let fixture = PhotoMediaRequestFixture()
        let degraded = UIImage(), final = UIImage()
        XCTAssertFalse(degraded === final)
        let result = await PhotoMediaRequest.image(request: { completion in
            completion(degraded, [PHImageResultIsDegradedKey: true])
            completion(final, [PHImageResultIsDegradedKey: false])
            completion(nil, nil)
            return 42
        }, cancel: fixture.cancel)

        XCTAssertTrue(result === final)
        XCTAssertTrue(fixture.cancelled.isEmpty)
    }

    func testImageCancellationStopsTheRequestWithoutWaitingForItsFinalCallback() async {
        let fixture = PhotoMediaRequestFixture()
        let callback = Mutex<((UIImage?, [AnyHashable: Any]?) -> Void)?>(nil)
        let started = expectation(description: "The image provider has registered its actual request")
        let finished = expectation(description: "Cancellation finishes without a PhotoKit result")
        let task = Task {
            let result = await PhotoMediaRequest.image(request: { completion in
                callback.withLock { $0 = completion }
                started.fulfill()
                return 42
            }, cancel: fixture.cancel)
            finished.fulfill()
            return result
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        let late = callback.withLock { value in
            defer { value = nil }
            return value
        }
        late?(UIImage(), nil)
        let result = await task.value

        XCTAssertNil(result)
        XCTAssertEqual(fixture.cancelled, [42])
    }

    func testSynchronousFinalResultWinsAndDuplicateCallbacksCannotResumeAgain() async {
        let fixture = PhotoMediaRequestFixture()
        let result: String? = await PhotoMediaRequest.load(request: { completion in
            completion("final")
            completion(nil)
            completion("late")
            return 42
        }, cancel: fixture.cancel)
        XCTAssertEqual(result, "final")
        XCTAssertTrue(fixture.cancelled.isEmpty)
    }

    func testAlreadyCancelledTaskDoesNotStartPhotoKitWork() async {
        let fixture = PhotoMediaRequestFixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await PhotoMediaRequest.load(request: fixture.request, cancel: fixture.cancel)
        }
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(fixture.starts, 0)
        XCTAssertTrue(fixture.cancelled.isEmpty)
    }

    func testCancellationAfterRegistrationResumesWithoutWaitingForPhotoKitAndCancelsExactlyOnce() async {
        let fixture = PhotoMediaRequestFixture()
        let started = expectation(description: "The actual provider registered a request")
        let task = Task {
            await PhotoMediaRequest.load(request: { completion in
                let id = fixture.request(completion)
                started.fulfill()
                return id
            }, cancel: fixture.cancel)
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        task.cancel()
        let result = await task.value
        fixture.complete("obsolete")
        fixture.complete(nil)
        XCTAssertNil(result)
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.cancelled, [42])
    }

    func testCancellationBeforeTheProviderReturnsItsRequestIDCleansUpThatLateID() async {
        let fixture = PhotoMediaRequestFixture()
        let task = Task {
            await PhotoMediaRequest.load(request: { completion in
                let id = fixture.request(completion)
                withUnsafeCurrentTask { $0?.cancel() }
                return id
            }, cancel: fixture.cancel)
        }
        let result = await task.value
        fixture.complete("obsolete")
        XCTAssertNil(result)
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.cancelled, [42])
    }

    func testFailedFinalResultIsReturnedWithoutCancellingCompletedWork() async {
        let fixture = PhotoMediaRequestFixture()
        let result: String? = await PhotoMediaRequest.load(request: { completion in
            completion(nil)
            return 42
        }, cancel: fixture.cancel)
        XCTAssertNil(result)
        XCTAssertTrue(fixture.cancelled.isEmpty)
    }
}

private final class PhotoMediaRequestFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((String?) -> Void)?
    private var cancellations: [PHImageRequestID] = []
    private var count = 0
    var starts: Int { lock.withLock { count } }
    var cancelled: [PHImageRequestID] { lock.withLock { cancellations } }

    func request(_ completion: @escaping (String?) -> Void) -> PHImageRequestID {
        lock.withLock { self.completion = completion; count += 1 }
        return 42
    }

    func cancel(_ id: PHImageRequestID) { lock.withLock { cancellations.append(id) } }
    func complete(_ value: String?) { lock.withLock { completion }?(value) }
}
