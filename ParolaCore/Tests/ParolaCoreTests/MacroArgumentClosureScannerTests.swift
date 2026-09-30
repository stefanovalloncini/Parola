import Testing
import ParolaTestSupport

@Suite("MacroArgumentClosureScanner")
struct MacroArgumentClosureScannerTests {
    @Test("flags a closure passed as an explicit argument inside a wrapper closure")
    func flagsParenClosureInWrapper() {
        let source = """
        await withMocksCleared {
            #expect(await waitUntil(timeoutMs: 5, { true }))
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("flags a chained sync closure inside a wrapper closure")
    func flagsChainedSyncClosureInWrapper() {
        let source = """
        await withMocksCleared {
            #expect(await store.list().first { $0.id == x } != nil)
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("flags a plain .contains closure inside a wrapper closure")
    func flagsContainsClosureInWrapper() {
        let source = """
        await withMocksCleared {
            #expect(list.contains { $0 == 2 })
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("flags a #require closure inside a wrapper closure")
    func flagsRequireClosureInWrapper() {
        let source = """
        await withMocksCleared {
            try #require(entries.first { $0.id != own.id })
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("flags #expect(throws:) trailing closure inside a wrapper closure")
    func flagsThrowsTrailingInWrapper() {
        let source = """
        await withMocksCleared {
            #expect(throws: E.self) {
                try thrower()
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("does not flag #expect(throws:) trailing closure at function level")
    func doesNotFlagThrowsTrailingAtFunctionLevel() {
        let source = """
        func f() {
            #expect(throws: E.self) {
                try thrower()
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("flags a closure sitting after the first comma")
    func flagsClosureAfterFirstComma() {
        let source = """
        await withMocksCleared {
            #expect(list.isEmpty, extra { true })
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("flags a closure spanning multiple lines inside a wrapper closure")
    func flagsMultiLineArgument() {
        let source = """
        await withMocksCleared {
            #expect(await waitUntil(timeoutMs: 5) {
                model.flag
            })
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("does not flag the same shapes at function level, no wrapper")
    func doesNotFlagAtFunctionLevel() {
        let source = """
        func f() async throws {
            #expect(await waitUntil(timeoutMs: 5, { true }))
            #expect(await store.list().first { $0.id == x } != nil)
            #expect(list.contains { $0 == 2 })
            try #require(entries.first { $0.id != own.id })
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("does not flag a brace inside a string literal that is itself a macro argument")
    func doesNotFlagBraceInString() {
        let source = """
        await withMocksCleared {
            #expect(s == "a { b } c")
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("does not flag a brace inside a raw string literal that is itself a macro argument")
    func doesNotFlagBraceInRawString() {
        let source = ##"""
        await withMocksCleared {
            #expect(s == #"x{"#)
        }
        """##
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("does not flag a brace inside a block comment inside a macro argument")
    func doesNotFlagBraceInComment() {
        let source = """
        await withMocksCleared {
            #expect(x /* { */ == 1)
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("does not flag a condition with no closure at all")
    func doesNotFlagPlainCondition() {
        let source = """
        await withMocksCleared {
            #expect(model.value == 1)
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("control-flow blocks at function level stay function-level safe")
    func controlFlowBlocksAreTransparent() {
        let source = """
        func f() {
            do {
                #expect(list.contains { $0 == 2 })
            }
            if true {
                #expect(list.contains { $0 == 3 })
            }
            for x in list {
                #expect(list.contains { $0 == x })
            }
            switch value {
            case 1:
                #expect(list.contains { $0 == 1 })
            default:
                break
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("a control-flow block inside a wrapper closure stays unsafe")
    func controlFlowInsideWrapperStaysUnsafe() {
        let source = """
        await withMocksCleared {
            if true {
                #expect(list.contains { $0 == 2 })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("get/set/willSet/didSet accessor bodies are function-level safe")
    func accessorBodiesAreSafe() {
        let source = """
        struct S {
            var computed: Bool {
                get {
                    #expect(list.contains { $0 == 1 })
                    return true
                }
                set {
                    #expect(list.contains { $0 == 2 })
                }
            }
            var observed: Int = 0 {
                willSet {
                    #expect(list.contains { $0 == 3 })
                }
                didSet {
                    #expect(list.contains { $0 == 4 })
                }
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("an implicit-getter computed property body is function-level safe")
    func implicitGetterIsSafe() {
        let source = """
        struct S {
            var computed: Bool {
                #expect(list.contains { $0 == 1 })
                return true
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("init, deinit, and subscript bodies are function-level safe")
    func initDeinitSubscriptAreSafe() {
        let source = """
        final class C {
            init() {
                #expect(list.contains { $0 == 1 })
            }
            deinit {
                #expect(list.contains { $0 == 2 })
            }
            subscript(i: Int) -> Int {
                #expect(list.contains { $0 == 3 })
                return i
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("a Task wrapper closure is unsafe, matching withMocksCleared")
    func taskWrapperIsUnsafe() {
        let source = """
        let t = Task {
            #expect(list.contains { $0 == 2 })
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    // MARK: - R1-1: continuation heuristics must not hide a wrapper closure

    @Test("an optional var declared right before a wrapper closure still flags it")
    func optionalVarBeforeWrapperStillFlags() {
        let source = """
        func f() async {
            var captured: String?
            await withMocksCleared { model in
                captured = model
                #expect(model.items.contains { $0 == 1 })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("a closure parameter list ending in 'in' then an if-let shorthand still flags the wrapper")
    func closureInThenIfLetShorthandStillFlags() {
        let source = """
        func f() async {
            await withMocksCleared { sink in
                if let latest {
                    #expect(sink.records.contains { $0 == latest })
                }
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("an optional-error var then a do block inside a wrapper still flags it")
    func optionalVarThenDoInWrapperStillFlags() {
        let source = """
        func f() async {
            await withMocksCleared {
                var thrown: Error?
                do {
                    #expect(list.contains { $0 == 2 })
                }
                _ = thrown
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("a typed let with no initializer then a wrapper still flags it")
    func typedLetNoInitializerThenWrapperStillFlags() {
        let source = """
        func f() async {
            let seen: Set<Int>
            await withMocksCleared { model in
                #expect(list.contains { $0 == 1 })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("a case-let pattern then a wrapper still flags it")
    func caseLetThenWrapperStillFlags() {
        let source = """
        func f() async {
            switch x {
            case .a(let v):
                await withMocksCleared { model in
                    #expect(v.contains { $0 == 1 })
                }
            default: break
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("the widened rule still finds exactly the 3 real allow-listed sites' shape")
    func stillFindsTheAllowListedShape() {
        let source = """
        struct RecordingTrustTests {
            func f() async throws {
                try await withMocksCleared(.transcriber) {
                    let entry = try #require(model.selectedEntryID.flatMap { model.libraryEntry(id: $0) })
                    #expect(entry.id == expected)
                }
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    // MARK: - R1-2: a closure hiding inside a string interpolation

    @Test("flags a closure inside a string interpolation used as the condition")
    func flagsClosureInConditionInterpolation() {
        let source = #"""
        await withMocksCleared {
            #expect("\(items.first { $0 > 1 }!)" == "x")
        }
        """#
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("flags a closure inside a string interpolation used as the message")
    func flagsClosureInMessageInterpolation() {
        let source = #"""
        await withMocksCleared {
            #expect(model.flag, "\(model.items.contains { $0 == 2 })")
        }
        """#
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("does not flag a plain brace argument sitting in a string with no interpolation")
    func doesNotFlagPlainBraceInStringArgument() {
        let source = """
        await withMocksCleared {
            #expect(renderedLog == "{ no interpolation here }")
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    // MARK: - R1-4: function-level false positives

    @Test("a force-unwrap then a for loop at function level stays safe")
    func forceUnwrapThenForStaysSafe() {
        let source = """
        func f() throws {
            let url = Bundle.main.url(forResource: "a", withExtension: "b")!
            for x in list {
                #expect(list.contains { $0 == x })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("a trailing comment ending in a period does not hide a following if block")
    func trailingCommentPeriodDoesNotHideIf() {
        let source = """
        func f() {
            let x = 1 // one.
            if flag {
                #expect(list.contains { $0 == x })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("a brace nested inside a paren call does not corrupt the depth for a later signature")
    func braceInsideParenDoesNotCorruptDepth() {
        let source = """
        struct S {
            let x = foo(a, { 1 }, b)
            @Test func bar(
                a: Int
            ) {
                #expect(list.contains { $0 == a })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("a where clause on its own line keeps the function body safe")
    func whereOnOwnLineStaysSafe() {
        let source = """
        func f<T>(_ t: T) -> Bool
        where T: Equatable {
            #expect(list.contains { $0 == 1 })
            return true
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("get with effects, and set with a parameter label, are both safe")
    func getSetWithEffectsAreSafe() {
        let source = """
        struct S {
            var a: Int {
                get async throws {
                    #expect(list.contains { $0 == 1 })
                    return 1
                }
            }
            var b: Int {
                get { 1 }
                set(newValue) {
                    #expect(list.contains { $0 == newValue })
                }
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("a local func declared inside a wrapper closure is function-level safe")
    func localFuncInWrapperStaysSafe() {
        let source = """
        func f() async {
            await withMocksCleared { model in
                func check() {
                    #expect(list.contains { $0 == 1 })
                }
                check()
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("if-let and guard-let inside a wrapper stay unsafe, not misread as declarations")
    func ifLetGuardLetInsideWrapperStayUnsafe() {
        let source = """
        func f() async {
            await withMocksCleared { model in
                if let v = x {
                    #expect(v.contains { $0 == 1 })
                }
                guard let w = y else { return }
                #expect(w.contains { $0 == 1 })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 2)
    }

    @Test("a for-in header's own #require never reads its following loop body as a trailing closure")
    func forHeaderRequireDoesNotStealTheLoopBody() {
        let source = """
        func f() async throws {
            await withMocksCleared { model in
                for x in try #require(items) {
                    print(x)
                }
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("a labeled 'init:' call argument is not misread as an init declaration")
    func labeledInitArgumentIsNotAnInitDeclaration() {
        let source = """
        func f() async {
            await make(init: 1) {
                #expect(list.contains { $0 == 1 })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    @Test("a multi-line dictionary literal with a trailing colon does not hide a later wrapper")
    func multilineDictLiteralDoesNotHideWrapper() {
        let source = """
        func f() async {
            let m = [
                "a": 1,
            ]
            await withMocksCleared { model in
                #expect(list.contains { $0 == 1 })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }

    // MARK: - R2-2: scan Unicode scalars, not grapheme clusters

    @Test("an emoji with a skin-tone modifier before a wrapper does not desync quote parity")
    func emojiSkinToneModifierDoesNotDesyncQuotes() {
        let source = """
        func f() async {
            let q = ["\u{1F44D}", "\u{1F3FD}"]
            await withMocksCleared { model in
                #expect(list.contains { $0 == 1 })
            }
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).count == 1)
    }
}
