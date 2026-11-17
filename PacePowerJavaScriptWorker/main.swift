import Darwin
import Foundation
import JavaScriptCore

private enum PacePowerJavaScriptWorker {
    private static func response(failure: String) -> Data {
        (try? JSONEncoder().encode(PaceJavaScriptPowerResponse(actions: [], failure: failure))) ?? Data()
    }

    static func evaluateJavaScript(_ request: PaceJavaScriptPowerRequest) -> Data {
        guard let context = JSContext() else { return response(failure: "JavaScript engine unavailable.") }
        var failed = false
        context.exceptionHandler = { _, _ in failed = true }
        guard let runner = context.evaluateScript(bootstrap), !failed,
              let result = runner.call(withArguments: [request.source, request.localHour, request.weekday]),
              !failed, result.isString, let serialized = result.toString(),
              let data = serialized.data(using: .utf8), data.count <= PaceJavaScriptPowerLimits.maximumOutputBytes,
              let actions = try? JSONDecoder().decode([PaceJavaScriptPowerAction].self, from: data),
              actions.count <= PaceJavaScriptPowerLimits.maximumActions else {
            return response(failure: "JavaScript failed validation or execution. Use only the supported Pace SDK with bounded output.")
        }
        return (try? JSONEncoder().encode(PaceJavaScriptPowerResponse(actions: actions, failure: nil))) ?? Data()
    }

    private static let bootstrap = #"""
    (function () {
        "use strict";
        const stringify = JSON.stringify.bind(JSON);
        const keys = Object.keys.bind(Object);
        const create = Object.create.bind(Object);
        const freeze = Object.freeze.bind(Object);
        const push = Function.call.bind(Array.prototype.push);
        const NativeFunction = Function;
        const NativeError = Error;
        freeze(Object.prototype); freeze(Array.prototype); freeze(Function.prototype); freeze(JSON);
        return function (source, localHour, weekday) {
            const actions = [];
            let invalid = false;
            function fail() { invalid = true; throw new NativeError("Invalid Pace SDK call"); }
            function text(value, maximum) {
                if (typeof value !== "string" || value.trim().length === 0 || value.length > maximum) fail();
                return value;
            }
            function options(value, allowed) {
                if (value === undefined) return create(null);
                if (value === null || typeof value !== "object" || Array.isArray(value)) fail();
                for (const key of keys(value)) if (!allowed.includes(key)) fail();
                return value;
            }
            function append(tool, argumentsObject) {
                if (actions.length >= 50) fail();
                const action = create(null); action.tool = tool; action.arguments = argumentsObject;
                push(actions, action);
                if (stringify(actions).length > 65536) fail();
            }
            const pace = create(null);
            pace.speak = function (spokenText, speechOptions) {
                const parsedOptions = options(speechOptions, ["profile", "englishSubtitle"]);
                const argumentsObject = create(null); argumentsObject.text = text(spokenText, 2000);
                if (parsedOptions.profile !== undefined) {
                    if (parsedOptions.profile !== "japanese_female") fail();
                    argumentsObject.profile = parsedOptions.profile;
                }
                if (parsedOptions.englishSubtitle !== undefined) argumentsObject.englishSubtitle = text(parsedOptions.englishSubtitle, 4000);
                append("speak", argumentsObject);
            };
            pace.presentMedia = function (assetID, mediaOptions) {
                const parsedOptions = options(mediaOptions, ["durationSeconds", "motion"]);
                const argumentsObject = create(null); argumentsObject.assetID = text(assetID, 80);
                if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(argumentsObject.assetID)) fail();
                const duration = parsedOptions.durationSeconds === undefined ? 8 : parsedOptions.durationSeconds;
                if (typeof duration !== "number" || !Number.isFinite(duration) || duration < 1 || duration > 30) fail();
                argumentsObject.durationSeconds = String(duration);
                if (parsedOptions.motion !== undefined) {
                    if (!["none", "bob", "dance"].includes(parsedOptions.motion)) fail();
                    argumentsObject.motion = parsedOptions.motion;
                }
                append("present_media", argumentsObject);
            };
            pace.presentSVG = function (svg, svgOptions) {
                const parsedOptions = options(svgOptions, ["durationSeconds"]);
                const argumentsObject = create(null); argumentsObject.svg = text(svg, 32768);
                const duration = parsedOptions.durationSeconds === undefined ? 8 : parsedOptions.durationSeconds;
                if (typeof duration !== "number" || !Number.isFinite(duration) || duration < 1 || duration > 30) fail();
                argumentsObject.durationSeconds = String(duration);
                append("present_media", argumentsObject);
            };
            pace.presentCard = function (card, cardOptions) {
                const parsedOptions = options(cardOptions, ["durationSeconds"]);
                if (card === null || typeof card !== "object" || Array.isArray(card)) fail();
                const serialized = stringify(card);
                const argumentsObject = create(null); argumentsObject.card = text(serialized, 49152);
                const duration = parsedOptions.durationSeconds === undefined ? 120 : parsedOptions.durationSeconds;
                if (typeof duration !== "number" || !Number.isFinite(duration) || duration < 1 || duration > 300) fail();
                argumentsObject.durationSeconds = String(duration);
                append("present_media", argumentsObject);
            };
            const immutableContext = create(null); immutableContext.localHour = localHour; immutableContext.weekday = weekday;
            const result = new NativeFunction("pace", "context", '"use strict";\n' + source)(freeze(pace), freeze(immutableContext));
            if (result !== undefined || invalid) fail();
            return stringify(actions);
        };
    })()
    """#
}


let maximumRequestBytes = PaceJavaScriptPowerLimits.maximumSourceBytes * 8
var requestData = Data()
while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
    requestData.append(chunk)
    guard requestData.count <= maximumRequestBytes else { exit(EXIT_FAILURE) }
}
guard let request = try? JSONDecoder().decode(PaceJavaScriptPowerRequest.self, from: requestData),
      request.source.utf8.count <= PaceJavaScriptPowerLimits.maximumSourceBytes,
      (0...23).contains(request.localHour), (1...7).contains(request.weekday) else { exit(EXIT_FAILURE) }
let response = PacePowerJavaScriptWorker.evaluateJavaScript(request)
guard response.count <= PaceJavaScriptPowerLimits.maximumOutputBytes else { exit(EXIT_FAILURE) }
try FileHandle.standardOutput.write(contentsOf: response)
