import Foundation

/// Bounded fit/held-out validation of UIKit contact metrics, never an estimate of actual force.
public enum TouchAimCalibrationAnalyzer {
    private struct Tuning:Sendable { var on:Double;var off:Double;var smoothing:Double;var enter:Int;var back:Int }
    private struct Metrics:Sendable {
        var error:Double;var movingError:Double;var stillError:Double
        var entries:Int;var missed:Bool;var unexpected:Int;var latency:Double
    }
    private struct Candidate:Sendable { var profile:TouchAimCalibrationProfile;var objective:Double;var falseEntries:Int;var missed:Int }
    public static func analyze(_ passes:[TouchAimCalibrationPass],name:String="iPhone touch calibration")throws->TouchAimCalibrationAnalysis {
        try validateProfileName(name)
        guard passes.count==4 else { return insufficient(name,"Record two Aim passes and two Aim + Shoot passes.") }
        guard passes.allSatisfy(validPass),Set(passes.map{"\($0.label.rawValue):\($0.repetition)"}).count==4 else { return insufficient(name,"A recording is incomplete, invalid or duplicated. Retake it with still and moving samples.") }
        let aim=passes.filter{$0.label == .aim}.sorted{$0.repetition<$1.repetition},shoot=passes.filter{$0.label == .shoot}.sorted{$0.repetition<$1.repetition}
        guard aim.count==2,shoot.count==2,aim.map(\.repetition)==shoot.map(\.repetition) else { return insufficient(name,"The two Aim/Shoot recording pairs do not match.") }
        let options:[[TouchAimMetric]]=[[.majorRadius],[.normalizedForce],[.majorRadius,.normalizedForce]]
        let candidates=options.compactMap{ evaluate(metrics:$0,aim:aim,shoot:shoot,name:name) }
        guard !candidates.isEmpty else { return .init(profile:.init(name:name,quality:.unreliable,summaries:passes.map(summary)),explanation:"No available touch metric increased consistently between the repeated Aim and Shoot recordings. Use manual controls instead of an automatic boundary.") }
        let ordered=candidates.sorted { a,b in
            if qualityRank(a.profile.quality) != qualityRank(b.profile.quality) { return qualityRank(a.profile.quality)>qualityRank(b.profile.quality) }
            if a.falseEntries != b.falseEntries { return a.falseEntries<b.falseEntries }
            if a.missed != b.missed { return a.missed<b.missed }
            if a.objective != b.objective { return a.objective<b.objective }
            return a.profile.transforms.count<b.profile.transforms.count
        }
        let single=ordered.first{$0.profile.transforms.count==1},combination=ordered.first{$0.profile.transforms.count>1}
        let chosen:Candidate
        if let single,let combination {
            if combination.falseEntries>single.falseEntries || combination.missed>single.missed || combination.profile.falseActivationRate>single.profile.falseActivationRate { chosen=single }
            else if qualityRank(combination.profile.quality)>qualityRank(single.profile.quality) { chosen=combination }
            else if qualityRank(combination.profile.quality)==qualityRank(single.profile.quality),single.objective-combination.objective>=0.02,combination.objective<=single.objective*0.8 { chosen=combination }
            else { chosen=single }
        } else { chosen=single ?? combination! }
        let explanation:String
        switch chosen.profile.quality {
        case .good:explanation="The detector separated the held-out recordings without accidental Shoot entries or missed Shoot passes. Complete the separate no-output validation before applying it."
        case .borderline:explanation="The detector has some separation but is close to a reliability limit. Complete the separate no-output validation; it may still be unsuitable."
        case .unreliable,.insufficient:explanation="Whole-pass validation did not establish a reliable boundary. This calibration cannot activate controls."
        }
        return .init(profile:chosen.profile,explanation:explanation)
    }
    /// A fresh Aim and Shoot recording form one separate validation flow. No output is produced.
    /// Returned profile is the only result marked validated; callers preserve the original on failure.
    public static func validate(_ profile:TouchAimCalibrationProfile,passes:[TouchAimCalibrationPass])throws->(profile:TouchAimCalibrationProfile,report:TouchAimCalibrationValidation) {
        try profile.validate()
        guard profile.quality == .good || profile.quality == .borderline,!profile.transforms.isEmpty else { throw ControllerPayloadError("This calibration is not reliable enough to validate for activation.") }
        guard passes.count==2,passes.allSatisfy(validPass),let aim=passes.first(where:{$0.label == .aim}),let shoot=passes.first(where:{$0.label == .shoot}) else { throw ControllerPayloadError("Validation needs one new Aim and one new Shoot recording, each with still and moving samples.") }
        guard passes.allSatisfy({ pass in pass.samples.allSatisfy { sample in profile.transforms.allSatisfy { sample.metrics.value(for:$0.metric) != nil } } }) else { throw ControllerPayloadError("A required calibration metric is unavailable in validation.") }
        let tuning=Tuning(on:profile.shootOn,off:profile.shootOff,smoothing:profile.smoothing,enter:profile.enterMilliseconds,back:profile.returnMilliseconds)
        let a=simulate(aim,transforms:profile.transforms,tuning:tuning),s=simulate(shoot,transforms:profile.transforms,tuning:tuning)
        let unexpected=a.unexpected+s.unexpected
        let passed=unexpected==0 && !s.missed && a.error<=0.005 && s.error<=0.30 && s.latency<=0.7
        var updated=profile;updated.validationCompleted=passed;updated.validationUnexpectedTransitions=unexpected
        let report=TouchAimCalibrationValidation(passed:passed,unexpectedTransitions:unexpected,falseActivationRate:a.error,missedActivationRate:s.error,
            explanation:passed ? "Separate no-output validation passed on these recordings. This is not a guarantee for other grips, movement or future touches.":"Validation did not pass. The calibration remains unavailable for activation; collect new recordings or use manual controls.")
        return (updated,report)
    }
    private static func insufficient(_ name:String,_ reason:String)->TouchAimCalibrationAnalysis { .init(profile:.init(name:name),explanation:reason) }
    private static func validPass(_ p:TouchAimCalibrationPass)->Bool {
        guard p.completed,(0...31).contains(p.repetition),(12...256).contains(p.samples.count),p.duration.isFinite,(0.3...30).contains(p.duration),
              p.samples.filter({$0.moving}).count>=6,p.samples.filter({!$0.moving}).count>=6,
              p.samples.allSatisfy({$0.metrics.isValid && $0.elapsed.isFinite && $0.elapsed>=0 && $0.elapsed<=p.duration}),
              p.samples.first!.elapsed<=p.duration*0.3,p.samples.last!.elapsed>=p.duration*0.75 else { return false }
        return zip(p.samples,p.samples.dropFirst()).allSatisfy{$0.elapsed<=$1.elapsed}
    }
    private static func evaluate(metrics:[TouchAimMetric],aim:[TouchAimCalibrationPass],shoot:[TouchAimCalibrationPass],name:String)->Candidate? {
        var folds:[(Tuning,Metrics,Metrics,Bool)]=[]
        for held in 0..<2 {
            let trainAim=[aim[1-held]],trainShoot=[shoot[1-held]]
            guard let transforms=fit(metrics:metrics,aim:trainAim,shoot:trainShoot) else { return nil }
            let t=tune(aim:trainAim,shoot:trainShoot,transforms:transforms)
            guard (aim[held].samples+shoot[held].samples).allSatisfy({sample in metrics.allSatisfy{sample.metrics.value(for:$0) != nil}}) else { return nil }
            let monotonic=metrics.allSatisfy { metric in median(shoot[held].samples.compactMap{$0.metrics.value(for:metric)})>median(aim[held].samples.compactMap{$0.metrics.value(for:metric)}) }
            folds.append((t,simulate(aim[held],transforms:transforms,tuning:t),simulate(shoot[held],transforms:transforms,tuning:t),monotonic))
        }
        guard let transforms=fit(metrics:metrics,aim:aim,shoot:shoot) else { return nil }
        let t=tune(aim:aim,shoot:shoot,transforms:transforms)
        let falseEntries=folds.reduce(0){$0+$1.1.entries},missed=folds.filter{$0.2.missed}.count,unexpected=folds.reduce(0){$0+$1.1.unexpected+$1.2.unexpected}
        let falseRate=folds.map{$0.1.error}.max()!,missRate=folds.map{$0.2.error}.max()!,latency=folds.map{$0.2.latency}.max()!
        let movementPenalty=folds.map{max(0,max($0.1.movingError-$0.1.stillError,$0.2.movingError-$0.2.stillError))}.max()!
        let movingDrop=shoot.contains { pass in median(pass.samples.filter(\.moving).map{score($0.metrics,transforms)}) < median(pass.samples.filter{!$0.moving}.map{score($0.metrics,transforms)})-0.1 }
        let effectivePenalty=max(movementPenalty,movingDrop ? 0.1:0)
        let movementReduced=effectivePenalty>0.05 || movingDrop
        let separation=max(0.001,abs(median(balanced(shoot).map{score($0.metrics,transforms)})-median(balanced(aim).map{score($0.metrics,transforms)})))
        let consistency=max(0,min(1,1-(folds.map{$0.0.on}.max()!-folds.map{$0.0.on}.min()!)/separation))
        let quality:TouchAimCalibrationQuality
        if folds.allSatisfy({$0.3}),falseEntries==0,missed==0,unexpected==0,latency<=0.3,falseRate<=0.005,missRate<=0.3,effectivePenalty<=0.08,consistency>=0.65 { quality = .good }
        else if folds.allSatisfy({$0.3}),falseEntries<=1,missed==0,unexpected<=2,latency<=0.7,falseRate<=0.03,missRate<=0.5,effectivePenalty<=0.2,consistency>=0.3 { quality = .borderline }
        else { quality = .unreliable }
        let profile=TouchAimCalibrationProfile(name:name,transforms:transforms,quality:quality,shootOn:t.on,shootOff:t.off,smoothing:t.smoothing,enterMilliseconds:t.enter,returnMilliseconds:t.back,
            falseActivationRate:falseRate,missedActivationRate:missRate,movementReducedReliability:movementReduced,consistency:consistency,summaries:(aim+shoot).map(summary))
        let objective=Double(falseEntries)*100+Double(missed)*30+Double(unexpected)*15+falseRate*15+missRate*2+effectivePenalty+(1-consistency)*0.1
        return .init(profile:profile,objective:objective,falseEntries:falseEntries,missed:missed)
    }
    private static func fit(metrics:[TouchAimMetric],aim:[TouchAimCalibrationPass],shoot:[TouchAimCalibrationPass])->[TouchAimSensorTransform]? {
        let all=(aim+shoot).flatMap(\.samples)
        guard all.allSatisfy({s in metrics.allSatisfy{s.metrics.value(for:$0) != nil}}) else { return nil }
        var transforms:[TouchAimSensorTransform]=[]
        for metric in metrics {
            let a=balanced(aim).compactMap{$0.metrics.value(for:metric)},s=balanced(shoot).compactMap{$0.metrics.value(for:metric)}
            let am=median(a),sm=median(s)
            guard sm>am,aim.indices.allSatisfy({i in median(shoot[i].samples.compactMap{$0.metrics.value(for:metric)})>median(aim[i].samples.compactMap{$0.metrics.value(for:metric)})}) else { return nil }
            let minimum=max((sm-am)*0.05,metric == .majorRadius ? 0.01:0.0001)
            transforms.append(.init(metric:metric,center:am,scale:max(spread(a,s),minimum)))
        }
        return transforms
    }
    private static func tune(aim:[TouchAimCalibrationPass],shoot:[TouchAimCalibrationPass],transforms:[TouchAimSensorTransform])->Tuning {
        let a=balanced(aim).map{score($0.metrics,transforms)},s=balanced(shoot).map{score($0.metrics,transforms)}
        let sorted=Array(Set(a+s)).sorted()
        let options=[sorted.first!-0.0001]+zip(sorted,sorted.dropFirst()).map{($0+$1)/2}+[sorted.last!+0.0001]
        let base=options.min { x,y in
            let xl=rate(a){$0>=x}*12+rate(s){$0<x},yl=rate(a){$0>=y}*12+rate(s){$0<y}
            if xl != yl { return xl<yl };let xf=rate(a){$0>=x},yf=rate(a){$0>=y};return xf==yf ? x>y:xf<yf
        }!
        let width=spread(a,s)
        var best=Tuning(on:min(8,max(-7.99,base)),off:min(7.99,max(-8,base-max(0.08,width*0.2))),smoothing:0.35,enter:96,back:120)
        var bestLoss=Double.infinity
        for onRaw in [base-width*0.08,base,base+width*0.08] {
            let on=min(8,max(-7.99,onRaw))
            for gap in [max(0.05,width*0.12),max(0.08,width*0.2),max(0.12,width*0.3)] {
                let off=max(-8,on-gap)
                for alpha in [0.22,0.35,0.5] { for enter in [64,96,128,160] { for back in [80,120,160,200] {
                    let t=Tuning(on:on,off:off,smoothing:alpha,enter:enter,back:back)
                    let am=aim.map{simulate($0,transforms:transforms,tuning:t)},sm=shoot.map{simulate($0,transforms:transforms,tuning:t)}
                    let entryLoss=Double(am.reduce(0){$0+$1.entries})*100
                    let missedLoss=Double(sm.filter(\.missed).count)*30
                    let transitionLoss=Double((am+sm).reduce(0){$0+$1.unexpected})*15
                    let errorLoss=am.map(\.error).reduce(0,+)/Double(am.count)*15 + sm.map(\.error).reduce(0,+)/Double(sm.count)*2
                    let loss=entryLoss+missedLoss+transitionLoss+errorLoss+Double(enter)*0.00005+Double(back)*0.00002

                    if loss<bestLoss { best=t;bestLoss=loss }
                } } }
            }
        }
        return best
    }
    private static func simulate(_ pass:TouchAimCalibrationPass,transforms:[TouchAimSensorTransform],tuning:Tuning)->Metrics {
        var detector=try! TwoStateTouchAimDetector(configuration:.init(shootOn:tuning.on,shootOff:tuning.off,smoothing:tuning.smoothing,enterMilliseconds:tuning.enter,returnMilliseconds:tuning.back,behavior:.pressOnEnter,hasShootPayload:false))
        _ = try! detector.begin(at:0)
        var entries=0,transitions=0,firstEntry:Double?,errors:[Bool]=[],moving:[Bool]=[],still:[Bool]=[]
        func observe(_ old:TouchAimState,_ time:Double) {
            if detector.state != old { transitions+=1;if detector.state == .shoot { entries+=1;if firstEntry == nil { firstEntry=time } } }
        }
        let evaluation=resample(pass.samples,count:min(600,max(16,Int(pass.duration/0.02)+1)))
        for sample in evaluation {
            if let due=detector.nextDeadline,due<=sample.elapsed {
                let before=detector.state;_ = try! detector.tick(at:due);observe(before,due)
            }
            let before=detector.state;_ = try! detector.observe(score:score(sample.metrics,transforms),at:sample.elapsed);observe(before,sample.elapsed)
            let error=pass.label == .aim ? detector.state == .shoot:detector.state != .shoot
            errors.append(error);if sample.moving { moving.append(error) } else { still.append(error) }
        }
        if let due=detector.nextDeadline,due<=pass.duration { let old=detector.state;_ = try! detector.tick(at:due);observe(old,due) }
        let expected=pass.label == .shoot && entries>0 ? 1:0
        return .init(error:boolRate(errors),movingError:boolRate(moving),stillError:boolRate(still),entries:pass.label == .aim ? entries:0,
            missed:pass.label == .shoot && entries==0,unexpected:max(0,transitions-expected),latency:pass.label == .shoot ? firstEntry ?? .infinity:0)
    }
    private static func score(_ metrics:TouchMetrics,_ transforms:[TouchAimSensorTransform])->Double {
        var sum=0.0,total=0.0
        for t in transforms { sum += min(8,max(-8,(metrics.value(for:t.metric)!-t.center)/t.scale))*t.weight;total += t.weight }
        return sum/total
    }
    private static func balanced(_ passes:[TouchAimCalibrationPass])->[TouchAimCalibrationSample] { passes.flatMap { p in [false,true].flatMap { moving in resample(p.samples.filter{$0.moving==moving},count:128) } } }
    private static func resample(_ samples:[TouchAimCalibrationSample],count:Int)->[TouchAimCalibrationSample] {
        guard !samples.isEmpty,count>0 else { return [] }
        let start=samples.first!.elapsed,end=samples.last!.elapsed
        var cursor=0
        return (0..<count).map { i in
            let target=start+(end-start)*Double(i)/Double(max(1,count-1))
            while cursor<samples.count-1 && abs(samples[cursor+1].elapsed-target)<=abs(samples[cursor].elapsed-target) { cursor+=1 }
            var result=samples[cursor];result.elapsed=target;return result
        }
    }
    private static func summary(_ p:TouchAimCalibrationPass)->TouchAimCalibrationSummary {
        let radius=p.samples.compactMap{$0.metrics.majorRadius},force=p.samples.compactMap{$0.metrics.normalizedForce}
        return .init(label:p.label,repetition:p.repetition,sampleCount:p.samples.count,stillCount:p.samples.filter{!$0.moving}.count,movingCount:p.samples.filter(\.moving).count,duration:p.duration,radiusMedian:radius.isEmpty ? nil:median(radius),forceMedian:force.isEmpty ? nil:median(force))
    }
    private static func qualityRank(_ q:TouchAimCalibrationQuality)->Int { q == .good ? 2:q == .borderline ? 1:0 }
    private static func boolRate(_ a:[Bool])->Double { a.isEmpty ? 0:Double(a.filter{$0}.count)/Double(a.count) }
    private static func rate(_ a:[Double],_ predicate:(Double)->Bool)->Double { a.isEmpty ? 0:Double(a.filter(predicate).count)/Double(a.count) }
    private static func median(_ a:[Double])->Double { percentile(a,0.5) }
    private static func percentile(_ a:[Double],_ p:Double)->Double {
        let sorted=a.sorted();guard !sorted.isEmpty else { return 0 }
        let position=p*Double(sorted.count-1),low=Int(position),high=min(low+1,sorted.count-1),weight=position-Double(low)
        return sorted[low]+(sorted[high]-sorted[low])*weight
    }
    private static func spread(_ a:[Double],_ b:[Double])->Double { max(0.000001,((percentile(a,0.9)-percentile(a,0.1))+(percentile(b,0.9)-percentile(b,0.1)))/2) }
}
