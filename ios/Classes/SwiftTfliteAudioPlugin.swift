import Flutter
import CoreLocation 
import UIKit
import TensorFlowLite
import AVFoundation
import RxCocoa
import RxSwift
import os


//  Interpreter result => dictionarty
struct Result: Codable {
    // let recognitionResult: RecognitionResult?
    let recognitionResult: String!
    let inferenceTime: Double
    let hasPermission: Bool
}

public class SwiftTfliteAudioPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    
    //placeholder variables
    private var events: FlutterEventSink!
    private var registrar: FlutterPluginRegistrar!
    private var result: FlutterResult!
    private var interpreter: Interpreter!
    private var lastInferenceRun: Bool = false
    
    //recording variables
    private var bufferSize: Int!
    private var sampleRate: Int!
    private var recording: Recording!
    // private var audioEngine: AVAudioEngine = AVAudioEngine()
    
    //Model variables
    private var inputSize: Int!
    private var inputType: String!
    private var inputShape: [Int]!
    private var outputRawScores: Bool!
    private var model: String!
    private var label: String!
    private var isAsset: Bool!
    private var numThreads: Int!
    private var numOfInferences: Int!
    
    //preprocessing variable
    private var audioDirectory: String!
    private var isPreprocessing: Bool = false
//    private var stopPreprocessing: Bool = false
    private let maxInt16AsFloat32: Float32 = 32767.0
    
    //labelsmoothing variables
    private var recognitionResult: LabelSmoothing?
    private var labelArray: [String] = []
    private var detectionThreshold: NSNumber!
    private var averageWindowDuration: Double!
    private var minimumTimeBetweenSamples: Double!
    private var suppressionTime: Double!
    
    //threads
    // private let conversionQueue = DispatchQueue(label: "conversionQueue")
    private let preprocessQueue = DispatchQueue(label: "preprocessQueue")
    private let group = DispatchGroup() //notifies whether recognition thread is done
    
    
    init(registrar: FlutterPluginRegistrar) {
        self.registrar = registrar
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SwiftTfliteAudioPlugin(registrar: registrar)
        
        let channel = FlutterMethodChannel(name: "tflite_audio", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        let audioRecognitionChannel = FlutterEventChannel(name: "AudioRecognitionStream", binaryMessenger: registrar.messenger())
        audioRecognitionChannel.setStreamHandler(instance)
        
        let fileRecognitionChannel = FlutterEventChannel(name: "FileRecognitionStream", binaryMessenger: registrar.messenger())
        fileRecognitionChannel.setStreamHandler(instance)
        
    }
    
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        self.result = result
        
        switch call.method{
        case "loadModel":
            let arguments: [String: AnyObject] = call.arguments as! [String: AnyObject] //DO NOT CHANGE POSITION
            self.numThreads = arguments["numThreads"] as? Int
            self.inputType = arguments["inputType"] as? String
            self.outputRawScores = arguments["outputRawScores"] as? Bool
            self.model = arguments["model"] as? String
            self.label = arguments["label"] as? String
            self.isAsset = arguments["isAsset"] as? Bool
            loadModel(registrar: registrar)
            break
        case "stopAudioRecognition":
            forceStopRecognition()
            break
        default: result(FlutterMethodNotImplemented)
        }
    }
    
    
    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        
        let arguments: [String: AnyObject] = arguments as! [String: AnyObject]
        self.events = events
        
        self.averageWindowDuration = arguments["averageWindowDuration"] as? Double
        self.detectionThreshold = arguments["detectionThreshold"] as? NSNumber
        self.minimumTimeBetweenSamples = arguments["minimumTimeBetweenSamples"] as? Double
        self.suppressionTime = arguments["suppressionTime"] as? Double
        
        let method = arguments["method"] as? String
        switch method {
        case "setAudioRecognitionStream":
            self.bufferSize = arguments["bufferSize"] as? Int
            self.sampleRate = arguments["sampleRate"] as? Int
            self.numOfInferences = arguments["numOfInferences"] as? Int
            checkPermissions()
            break
        case "setFileRecognitionStream":
            //TODO - dont need to have external permission?
            self.audioDirectory = arguments["audioDirectory"] as? String
            preprocessAudioFile()
            break
        default:
            print("Unknown method type with listener")
        }
        
        return nil
    }
    
    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.events = nil
        return nil
    }
    
    func loadModel(registrar: FlutterPluginRegistrar){
        
        var modelPath: String
        var modelKey: String
        
        //Get model path
        if(isAsset){
            modelKey = registrar.lookupKey(forAsset: model)
            modelPath = Bundle.main.path(forResource: modelKey, ofType: nil)!
        } else {
            modelPath = model
        }
        
        // Specify the options for the `Interpreter`.
        var options = Interpreter.Options()
        options.threadCount = numThreads
        
        do {
            // Create the `Interpreter` and allocate memory for the model's input `Tensor`s.
            self.interpreter = try Interpreter(modelPath: modelPath, options: options)
            try interpreter.allocateTensors()
            
            self.inputShape = try interpreter.input(at: 0).shape.dimensions
            self.inputSize = inputShape.max()
            print("Input shape: \(inputShape!)")
            print("Input size \(inputSize!)")
            print("Input type \(inputType!)")
            
        } catch let error {
            print("Failed to create the interpreter with error: \(error.localizedDescription)")
            //return nil
        }
        
        //Load labels
        if(label.count > 0){
            if(isAsset){
                let labelKey = registrar.lookupKey(forAsset: label)
                let labelPath = Bundle.main.url(forResource: labelKey, withExtension: nil)!
                loadLabels(labelPath: labelPath as URL)
            } else {
                let labelPath = URL(string: label)
                loadLabels(labelPath: labelPath!)
            }
        }
        
    }
    
    //reads text files and retrieves values to string array
    //also removes any emptyspaces of nil values in array
    private func loadLabels(labelPath: URL){
        let contents = try! String(contentsOf: labelPath, encoding: .utf8)
        labelArray = contents.components(separatedBy: CharacterSet.newlines).filter({ $0 != ""})
        print("labels: \(labelArray)")
    }
    
    func checkPermissions() {
        
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            print("Permission granted")
            startMicrophone()
        case .denied:
            showAlert(title: "Microphone Permissions", message: "Permission denied. Please accept permission in your settings.")
            let finalResults = Result(recognitionResult: nil, inferenceTime: 0, hasPermission: false)
            let dict = finalResults.dictionary
            if events != nil {
                print(dict!)
                events(dict!)
                self.events(FlutterEndOfEventStream)
            }
        case .undetermined:
            print("requesting permission")
            requestPermissions()
        @unknown default:
            print("Something weird just happened")
        }
    }
    
    
    func requestPermissions() {
        AVAudioSession.sharedInstance().requestRecordPermission { (granted) in
            if granted {
                
                self.startMicrophone()
            }
            else {
                print("check permissions")
                self.checkPermissions()
            }
        }
    }
    
    func showAlert(title: String, message: String) {
        
        DispatchQueue.main.async {
            let alertController = UIAlertController(title: title, message:
                                                        message, preferredStyle: .alert)
            let rootViewController = UIApplication.shared.keyWindow?.rootViewController
            let settingsAction = UIAlertAction(title: "Settings", style: .default) { (_) -> Void in
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }
                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl, completionHandler: { (success) in })
                }
            }
            let cancelAction = UIAlertAction(title: "Cancel", style: .default, handler: nil)
            alertController.addAction(cancelAction)
            alertController.addAction(settingsAction)
            rootViewController?.present(alertController, animated: true, completion: nil)
        }
    }
    
    func preprocessAudioFile(){
        print("Preprocessing audio file..")
        
        var data: Data
        let inputSize = self.inputSize!
        
        if(isAsset){
            let audioKey = registrar.lookupKey(forAsset: audioDirectory)
            let audioPath = Bundle.main.path(forResource: audioKey, ofType: nil)!
            // data = try! Data(contentsOfFile: audioPath)
            data = NSData(contentsOfFile: audioPath)! as Data
            
        } else {
            let audioPath = audioDirectory;
            let url = URL(string: audioPath!)
            data = try! Data(contentsOf: url!)
        }
        
        //TODO - dont need to extract audio data????
        //TODO - get sample rate and channels
        //TODO - assert that it has be to be wav file, and mono
        //let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)
        //let rawData = data.convertedTo(format!)
        
        //TODO - Fix deprecation
        let int16Data = data.withUnsafeBytes {
            UnsafeBufferPointer<Int16>(start: $0, count: data.count/2).map(Int16.init(littleEndian:))
        }
        
        
        //If missing samples are more than half, padding will be done.
        //Too little samples, is pointless to pad.)
        let int16DataSize = int16Data.count
        let remainingSamples = int16DataSize % inputSize
        let missingSamples = inputSize - remainingSamples
        let totalWithPad = int16DataSize + missingSamples
        let totalWithoutPad = int16DataSize - remainingSamples
        //!To debug requirePadding, simply change original [>] to < before (inputSize/2)
        // let requirePadding: Bool = remainingSamples > (inputSize/2) ? true : false //TODO - Make this user controlled?
        let requirePadding = true
        let numOfInferences: Int = requirePadding == true ? Int(totalWithPad/inputSize) : Int(totalWithoutPad/inputSize)
        
        
        //!debugging
        print("int16DataSize: \(int16DataSize)")
        print("inputSize: \(inputSize)")
        print("remainingSamples: \(remainingSamples)")
        print("missingSamples: \(missingSamples)")
        print("totalWithPad: \(totalWithPad)")
        print("totalWithoutPad: \(totalWithoutPad)")
        print("require padding: \(requirePadding)")
        print("true: \(totalWithPad/inputSize)")
        print("false: \(totalWithoutPad/inputSize)")
        print("numOfInferences: \(numOfInferences)")
        
        
        //breaks intData16 array into chunks, so it can be fed to the model
        var startCount = 0
        var endCount = inputSize
        self.isPreprocessing = true
        
        self.preprocessQueue.async{ [self] in
            for inferenceCount in 1...numOfInferences{
            
                //used to forcibly stop preprocessing
                if(self.isPreprocessing == false){
                    break
                }

                if(inferenceCount != numOfInferences){
                    print("inference Count: \(inferenceCount)/\(numOfInferences)")
                    recognize(onBuffer: Array(int16Data[startCount..<endCount]))
                    startCount = endCount
                    endCount += inputSize
                }else{
                    if(requirePadding){
                        print("inference count: \(inferenceCount)/\(numOfInferences)")
                        print("Padding missing samples to audio chunk")
                        
                        endCount -= missingSamples
                        let remainingArray = int16Data[startCount..<endCount]
                        let silenceArray: [Int16] = (-10...10).randomElements(missingSamples)
                        var paddedArray: [Int16] = []
                        paddedArray.append(contentsOf: remainingArray)
                        paddedArray.append(contentsOf: silenceArray)
                        
                        //!debug
                        assert(paddedArray.count == inputSize, "Error. Mismatch with paddedArray")
                        assert(startCount == totalWithoutPad, "Error. startCount does not match")
                        assert(endCount == (totalWithPad-missingSamples), "Error. end count does not match")
                        //  assert(paddedArray[remainingSamples-1] == remainingArray[remainingSamples-1], "Error, padded array mismatch")
                        //  print(startCount)
                        //  print(endCount)
                        //  print(silenceArray.count)
                        //  print(paddedArray.count)
                        
                        recognize(onBuffer: Array(paddedArray[0..<inputSize]))
                        self.lastInferenceRun = true
                        self.isPreprocessing = false
                        stopRecognition()
                    }else{
                        print("inference Count: \(inferenceCount)/\(numOfInferences)")
                        print("Remaing audio file is too small. Skipping recognition")
                        self.lastInferenceRun = true
                        self.isPreprocessing = false
                        stopRecognition()
                    }
                }   
            }
        }

   
    }
    
    
    func startMicrophone(){
        print("start microphone")

        recording = Recording(
            bufferSize: bufferSize, 
            inputSize: inputSize,
            sampleRate: sampleRate, 
            numOfInferences: numOfInferences)

        let main = MainScheduler.instance
        let concurrentBackground = ConcurrentDispatchQueueScheduler.init(qos: .background)
        
        recording.getObservable()
            .subscribe(on: concurrentBackground)
            .observe(on: main)   
            .subscribe(
                onNext: { audioChunk in self.recognize(onBuffer: audioChunk)},
                onError: { error in print(error)},
                onCompleted: { self.lastInferenceRun = true },
                onDisposed: {print("disposed")})
            
        recording.start()
        
    }
    
    func recognize(onBuffer buffer: [Int16]){
        print("Running model")
        
        if(events == nil){
            print("events is null. Breaking recognition")
            return
        }
        
        var interval: TimeInterval!
        var outputTensor: Tensor!
        // print(outputRawScores!)
        // let outputRawScores = true
           
        do {
            // Copy the `[Int16]` buffer data as an array of `Float`s to the audio buffer input `Tensor`'s.
            let audioBufferData = Data(copyingBufferOf: buffer.map { Float($0) / maxInt16AsFloat32 })
            try interpreter.copy(audioBufferData, toInputAt: 0)
            
            if(inputType != "decodedWav" && inputType != "rawAudio"){
                assertionFailure("Input type does not match decodedWav or rawAudio")
            }
            
            if(inputType == "decodedWav"){
                // Copy the sample rate data to the sample rate input `Tensor`.
                var rate = Int32(sampleRate)
                let sampleRateData = Data(bytes: &rate, count: MemoryLayout.size(ofValue: rate))
                try interpreter.copy(sampleRateData, toInputAt: 1)
            }
            
            // Calculate inference time
            let startDate = Date()
            try interpreter.invoke() //required!!! Do not touch
            interval = Date().timeIntervalSince(startDate) * 1000
            
            // Get the output `Tensor` to process the inference results.
            outputTensor = try interpreter.output(at: 0)
            
        } catch let error {
            print("Failed to invoke the interpreter with error: \(error.localizedDescription)")
        }
        
        print(detectionThreshold!)
        
        
        // Gets the formatted and averaged results.
        let scores = [Float32](unsafeData: outputTensor.data) ?? []
        let normalizedScores = scores.map { $0.isFinite ? $0 : 0.0 }
        let finalResults: Result!
        let roundInterval = interval.rounded()

        //Set parameters for label smoothing
        recognitionResult = LabelSmoothing(
            averageWindowDuration: averageWindowDuration!,
            detectionThreshold: detectionThreshold!.floatValue as Float,
            minimumTimeBetweenSamples: minimumTimeBetweenSamples!,
            suppressionTime: suppressionTime!,
            classLabels: labelArray
        )

        
        
        //debugging
        print("Raw Label Scores:")
        dump(scores)
        
        
        if(outputRawScores == false){

            let results = getResults(withScores: normalizedScores)
            finalResults = Result(recognitionResult: results, inferenceTime: roundInterval, hasPermission: true)
        }else{
            //convert array to exact string value
            let data = try? JSONSerialization.data(withJSONObject: normalizedScores)
            let stringValue = String(data: data!, encoding: String.Encoding.utf8)
            finalResults = Result(recognitionResult: stringValue, inferenceTime: roundInterval, hasPermission: true)
        }
        
        // Convert results to dictionary and json.
        let dict = finalResults.dictionary
        if(events != nil){
            print("results: \(dict!)")
            events(dict!)
        }
        
        self.stopRecognition();
        
         
    }
    
    
    // private func getResults(withScores scores: [Float]) -> RecognitionResult? {
    private func getResults(withScores scores: [Float]) -> String? {
        
        // Runs results through recognize commands.
        let command = recognitionResult?.process(
            latestResults: scores,
            currentTime: Date().timeIntervalSince1970 * 1000
        )
        
        //Check if command is new and the identified result is not silence or unknown.
        // guard let newCommand = command,
        //   let index = labelArray.firstIndex(of: newCommand.name),
        //   newCommand.isNew,
        //   index >= labelOffset
        // else {
        //     return nil
        // }
        return command?.name
    }
    
    func forceStopRecognition(){
        self.lastInferenceRun = true
    
        stopPreprocessing()
        stopRecording()
        stopRecognition()
    }

    func stopRecognition(){
        if(events != nil && lastInferenceRun == true){
            print("recognition stream stopped")
            self.lastInferenceRun = false
            self.events(FlutterEndOfEventStream)
        }
    }


    func stopRecording(){
        print("Recording stopped.") //Add conditional - prints in preprocessing
        recording.stop()
    }

    func stopPreprocessing(){
        if(self.isPreprocessing == true){
            self.isPreprocessing = false
            print("stop preprocessing audio file") 
        }
    }
}


//----------------EXTENSIONS-----------

//Used in runModel()
extension Data {
    /// Creates a new buffer by copying the buffer pointer of the given array.
    ///
    /// - Warning: The given array's element type `T` must be trivial in that it can be copied bit
    ///     for bit with no indirection or reference-counting operations; otherwise, reinterpreting
    ///     data from the resulting buffer has undefined behavior.
    /// - Parameter array: An array with elements of type `T`.
    init<T>(copyingBufferOf array: [T]) {
        self = array.withUnsafeBufferPointer(Data.init)
    }
}

//Used for startMicrophone()
extension Array {
    /// Creates a new array from the bytes of the given unsafe data.
    ///
    /// - Warning: The array's `Element` type must be trivial in that it can be copied bit for bit
    ///     with no indirection or reference-counting operations; otherwise, copying the raw bytes in
    ///     the `unsafeData`'s buffer to a new array returns an unsafe copy.
    /// - Note: Returns `nil` if `unsafeData.count` is not a multiple of
    ///     `MemoryLayout<Element>.stride`.
    /// - Parameter unsafeData: The data containing the bytes to turn into an array.
    init?(unsafeData: Data) {
        guard unsafeData.count % MemoryLayout<Element>.stride == 0 else { return nil }
#if swift(>=5.0)
        self = unsafeData.withUnsafeBytes { .init($0.bindMemory(to: Element.self)) }
#else
        self = unsafeData.withUnsafeBytes {
            .init(UnsafeBufferPointer<Element>(
                start: $0,
                count: unsafeData.count / MemoryLayout<Element>.stride
            ))
        }
#endif  // swift(>=5.0)
    }
}

// Used to encode the struct class Result to json
extension Encodable {
    var dictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)).flatMap { $0 as? [String: Any] }
    }
}

extension Decodable {
    init(from: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: from, options: .prettyPrinted)
        let decoder = JSONDecoder()
        self = try decoder.decode(Self.self, from: data)
    }
}

//https://stackoverflow.com/questions/28140145/create-an-array-of-random-numbers-in-swift
extension RangeExpression where Bound: FixedWidthInteger {
    func randomElements(_ n: Int) -> [Bound] {
        precondition(n > 0)
        switch self {
        case let range as Range<Bound>: return (0..<n).map { _ in .random(in: range) }
        case let range as ClosedRange<Bound>: return (0..<n).map { _ in .random(in: range) }
        default: return []
        }
    }
}
