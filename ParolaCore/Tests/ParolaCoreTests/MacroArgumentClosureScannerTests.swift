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

    @Test("does not flag a brace inside a string literal near a closure-free #expect")
    func doesNotFlagBraceInString() {
        let source = """
        await withMocksCleared {
            let s = "a { b } c"
            #expect(s.count == 9)
        }
        """
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("does not flag a brace inside a raw string literal")
    func doesNotFlagBraceInRawString() {
        let source = #"""
        await withMocksCleared {
            let s = #"weird"cmd\name{x}"#
            #expect(s.count == 9)
        }
        """#
        #expect(MacroArgumentClosureScanner.violations(in: source).isEmpty)
    }

    @Test("does not flag a brace inside a comment")
    func doesNotFlagBraceInComment() {
        let source = """
        await withMocksCleared {
            // a comment with { a brace } in it
            #expect(1 == 1)
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
                list.contains { $0 == 1 } && expect2()
            }
            func expect2() -> Bool {
                #expect(list.contains { $0 == 2 })
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
}
