import Foundation
import Testing

@testable import DevPanelKit

@Suite("ShellWords")
struct ShellWordsTests {
    @Test("blanks separate words; runs of spaces, tabs and newlines collapse")
    func whitespace() {
        #expect(ShellWords.split("mvn  spring-boot:run").argv == ["mvn", "spring-boot:run"])
        #expect(ShellWords.split("  a\tb \n c  ").argv == ["a", "b", "c"])
        #expect(ShellWords.split("").argv == [])
        #expect(ShellWords.split("   ").argv == [])
    }

    @Test("single quotes are literal; double quotes allow \\\" \\\\ \\$ \\` only")
    func quotes() {
        #expect(ShellWords.split(#"echo 'a b' "c d""#).argv == ["echo", "a b", "c d"])
        #expect(ShellWords.split(#"x 'it\'"#).argv == ["x", #"it\"#], "backslash is literal inside single quotes")
        #expect(ShellWords.split(#""a\"b" "c\\d" "e\$f" "g\nh""#).argv == [#"a"b"#, #"c\d"#, "e$f", #"g\nh"#])
        #expect(ShellWords.split(#"a"b c"d"#).argv == ["ab cd"], "adjacent quoted parts join one word")
        #expect(ShellWords.split("'' x").argv == ["", "x"], "empty quotes are an empty argument")
        #expect(ShellWords.split(#"--opt="${host}:${port}""#).argv == ["--opt=${host}:${port}"])
    }

    @Test("a backslash outside quotes escapes the next character; trailing backslash is kept")
    func escapes() {
        #expect(ShellWords.split(#"a\ b c"#).argv == ["a b", "c"])
        #expect(ShellWords.split(#"\'x"#).argv == ["'x"])
        #expect(ShellWords.split(#"x\"#).argv == [#"x\"#])
        #expect(ShellWords.split("a\\\nb").argv == ["ab"], "backslash-newline is a line continuation")
    }

    @Test("unclosed quotes are errors")
    func unclosed() {
        #expect(ShellWords.split(#"echo "abc"#).error == .unclosedDoubleQuote)
        #expect(ShellWords.split("echo 'abc").error == .unclosedSingleQuote)
        #expect(ShellWords.split(#"echo "abc"#).error?.description == "双引号未闭合")
        #expect(ShellWords.split("a b").error == nil)
    }

    @Test("operators are ordinary characters (argv, never a shell string)")
    func operators() {
        #expect(ShellWords.split("npm run dev &").argv == ["npm", "run", "dev", "&"])
        #expect(ShellWords.split("a&&b").argv == ["a&&b"])
    }

    @Test("join/quote round-trips through split", arguments: [
        ["./mvnw", "spring-boot:run", "-Dspring-boot.run.profiles=${profile}"],
        ["echo", "a b", "", "it's", #"q"uote"#, "back\\slash", "$HOME", "&", "tab\there", "new\nline"],
        ["uv", "run", "uvicorn", "app.main:app", "--port", "${port}"],
        ["--server.port=${apiPort} --server.address=${host}"],
    ])
    func roundTrip(argv: [String]) {
        let line = ShellWords.join(argv)
        #expect(ShellWords.split(line).argv == argv, "\(line)")
        #expect(ShellWords.split(line).error == nil)
    }

    @Test("quote leaves safe words alone")
    func quoteSafe() {
        #expect(ShellWords.quote("spring-boot:run") == "spring-boot:run")
        #expect(ShellWords.quote("/opt/homebrew/bin/mvn") == "/opt/homebrew/bin/mvn")
        #expect(ShellWords.quote("a b") == "'a b'")
        #expect(ShellWords.quote("${x}") == "'${x}'")
        #expect(ShellWords.quote("") == "''")
    }

    @Test("shell form: [/bin/zsh|bash|sh, -lc|-c, script] only")
    func shellForm() {
        #expect(ShellWords.shellForm(["/bin/zsh", "-lc", "a && b"]) == .init(shell: "/bin/zsh", flag: "-lc", script: "a && b"))
        #expect(ShellWords.shellForm(["bash", "-c", "x"])?.shell == "bash")
        #expect(ShellWords.shellForm(["/bin/zsh", "-lc", "x", "extra"]) == nil)
        #expect(ShellWords.shellForm(["/usr/bin/env", "-c", "x"]) == nil)
        #expect(ShellWords.shellForm(["/bin/zsh", "-x", "x"]) == nil)
    }

    @Test("background detection", arguments: [
        ("npm run dev &", "&"),
        ("npm run dev&", "&"),
        ("a & b", "&"),
        ("nohup java -jar app.jar", "nohup"),
        ("/usr/bin/nohup x", "nohup"),
        ("cd web; nohup npm start", "nohup"),
        ("setsid x", "setsid"),
        ("x && disown", "disown"),
        ("docker compose up -d", "-d"),
        ("docker run -itd nginx", "-d"),
        ("docker-compose up --detach", "-d"),
        ("podman run -d x", "-d"),
    ])
    func background(text: String, expected: String) {
        #expect(ShellWords.backgroundHint(text) == expected)
    }

    @Test("not background", arguments: [
        "npm run dev", "a && b", "a || b", "x 2>&1", "x &>log", "x >&2", "echo 'a & b'", #"echo "nohup""#,
        "echo nohup", "docker compose up", "docker run -it nginx", "mvn -d", "a\\&b", "",
    ])
    func notBackground(text: String) {
        #expect(ShellWords.backgroundHint(text) == nil)
    }
}

@Suite("Slug")
struct SlugTests {
    @Test("names → service IDs")
    func names() {
        #expect(Slug.make("后端", taken: []) == "backend")
        #expect(Slug.make("前端 Web", taken: []) == "frontend-web")
        #expect(Slug.make("Web Admin", taken: []) == "web-admin")
        #expect(Slug.make("  API--Gateway!! ", taken: []) == "api-gateway")
        #expect(Slug.make("123abc", taken: []) == "abc", "must start with a letter")
        #expect(Slug.make("", taken: []) == "service")
        #expect(Slug.make("日志", taken: []) == "service", "no ASCII left")
        #expect(Slug.make("数据库", taken: []) == "db")
    }

    @Test("de-duplicates against taken IDs")
    func dedupe() {
        #expect(Slug.make("后端", taken: ["backend"]) == "backend-2")
        #expect(Slug.make("后端", taken: ["backend", "backend-2"]) == "backend-3")
        #expect(Slug.make("x", taken: ["backend"]) == "x")
    }

    @Test("long names are cut to 28 characters without a trailing dash")
    func long() {
        let s = Slug.make(String(repeating: "abcdefg ", count: 8), taken: [])
        #expect(s.count <= 28)
        #expect(!s.hasSuffix("-"))
        #expect(Slug.isValidServiceID(s))
        #expect(Slug.isValidServiceID(Slug.make(String(repeating: "a", count: 40), taken: [String(repeating: "a", count: 28)])))
    }

    @Test("ID format /^[a-z][a-z0-9-]{0,31}$/")
    func format() {
        #expect(Slug.isValidServiceID("api"))
        #expect(Slug.isValidServiceID("a-1"))
        #expect(!Slug.isValidServiceID("Api"))
        #expect(!Slug.isValidServiceID("1a"))
        #expect(!Slug.isValidServiceID("a_b"))
        #expect(!Slug.isValidServiceID(""))
        #expect(!Slug.isValidServiceID(String(repeating: "a", count: 33)))
        #expect(Slug.isValidServiceID(String(repeating: "a", count: 32)))
    }
}

@Suite("ProjectDraft")
struct ProjectDraftTests {
    static func orderService() throws -> Project {
        try Fixture.decode(Project.self, "recorded/project-order-service.json")
    }

    /// The config a lossless round trip must give back: params without response-only fields.
    static func requestForm(_ c: ProjectConfig) -> ProjectConfig {
        var c = c
        c.params = c.params?.map(\.forRequest)
        return c
    }

    @Test("recorded configs round-trip losslessly", arguments: [
        "recorded/project-order-service.json", "recorded/project-ml-api-secret-param.json",
        "recorded/update-response-kept.json", "handwritten/project-params-all-types.json",
    ])
    func roundTrip(fixture: String) throws {
        let project = try Fixture.decode(Project.self, fixture)
        let draft = ProjectDraft(config: project.config)
        let built = draft.build(.save)
        #expect(built.errors.isEmpty, "\(built.errors)")
        #expect(built.config == Self.requestForm(project.config))
        // Validation form is identical too (no typed secrets).
        #expect(draft.build(.validate).config == Self.requestForm(project.config))
        #expect(!draft.hasTypedSecrets)
    }

    @Test("params are carried over unchanged, secret params stay without a value")
    func params() throws {
        let project = try Fixture.decode(Project.self, "recorded/project-ml-api-secret-param.json")
        let built = ProjectDraft(config: project.config).build(.save).config
        let original = try #require(project.config.params)
        let carried = try #require(built.params)
        #expect(carried.map(\.key) == original.map(\.key))
        #expect(carried.allSatisfy { $0.usedBy == nil && $0.setBy == nil && $0.valueUpdatedAt == nil })
        let secret = try #require(carried.first { $0.isSecret })
        #expect(secret.value == nil, "keep the stored secret value")
        let body = try json(UpdateRequest(ifRevision: 1, config: built))
        let params = try #require((body["config"] as? [String: Any])?["params"] as? [[String: Any]])
        #expect(params.count == original.count)
    }

    @Test("a masked secret env value is sent as {secret:true} (keep)")
    func secretKeep() throws {
        let project = try Self.orderService()
        let draft = ProjectDraft(config: project.config)
        let row = try #require(draft.services[0].env.first { $0.name == "DB_PASSWORD" })
        #expect(row.secret && row.storedName == "DB_PASSWORD" && row.value.isEmpty)
        let built = draft.build(.save).config
        #expect(built.services[0].env?["DB_PASSWORD"] == .secret(value: nil))
        let body = try json(built)
        let svc = try #require((body["services"] as? [[String: Any]])?.first)
        let env = try #require(svc["env"] as? [String: Any])
        #expect(env["DB_PASSWORD"] as? [String: Bool] == ["secret": true])
    }

    @Test("typed secret: sent on save, masked for validation; makes the draft dirty")
    func secretTyped() throws {
        var draft = ProjectDraft(config: try Self.orderService().config)
        let i = try #require(draft.services[0].env.firstIndex { $0.name == "DB_PASSWORD" })
        draft.services[0].env[i].value = "s3cret"
        #expect(draft.build(.save).config.services[0].env?["DB_PASSWORD"] == .secret(value: "s3cret"))
        #expect(draft.build(.validate).config.services[0].env?["DB_PASSWORD"] == .secret(value: nil))
        #expect(draft.hasTypedSecrets)
    }

    @Test("a secret cannot be kept under a new name or a new service ID")
    func secretMoved() throws {
        let base = ProjectDraft(config: try Self.orderService().config)
        let i = try #require(base.services[0].env.firstIndex { $0.name == "DB_PASSWORD" })

        var renamed = base
        renamed.services[0].env[i].rename("DB_PASS")
        #expect(renamed.build(.save).errors["services[0].env.DB_PASS"] == "请填写 DB_PASS 的值")

        var moved = base
        moved.services[0].setServiceId("api")
        #expect(moved.build(.save).errors["services[0].env.DB_PASSWORD"] != nil)
        #expect(moved.build(.validate).errors["services[0].env.DB_PASSWORD"] == nil, "validation never needs values")

        var fresh = ProjectDraft.empty()
        fresh.services[0].env = [EnvRow(name: "API_TOKEN", value: "", secret: true)]
        #expect(fresh.build(.save).errors["services[0].env.API_TOKEN"] == "请填写 API_TOKEN 的值")
    }

    @Test("secret switch follows the name (TOKEN, SECRET, PASSWORD, KEY) until touched")
    func secretByName() {
        var row = EnvRow()
        row.rename("OPENAI_API_KEY")
        #expect(row.secret)
        row.rename("PORT")
        #expect(!row.secret)
        row.rename("hf_token")
        #expect(row.secret)
        row.setSecret(false)
        row.rename("MY_SECRET")
        #expect(!row.secret, "manual choice wins")
        #expect(EnvRow.looksSecret("DB_PASSWORD"))
        #expect(!EnvRow.looksSecret("JAVA_HOME"))
    }

    @Test("shell form is edited as the script and saved back as [shell, flag, script]")
    func shell() {
        let config = ProjectConfig(name: "x", root: "/tmp/x", services: [
            ServiceConfig(id: "a", name: "A", cwd: ".", command: ["/bin/bash", "-c", "npm i && npm run dev"]),
        ])
        var draft = ProjectDraft(config: config)
        #expect(draft.services[0].viaShell)
        #expect(draft.services[0].commandText == "npm i && npm run dev")
        #expect(draft.services[0].shell == "/bin/bash" && draft.services[0].shellFlag == "-c")
        #expect(draft.build().config == config)

        draft.services[0].viaShell = false
        #expect(draft.services[0].command == .argv(["npm", "i", "&&", "npm", "run", "dev"]))
        draft.services[0].viaShell = true
        draft.services[0].commandText = "echo 'hi' | cat"
        #expect(draft.build().config.services[0].command == ["/bin/bash", "-c", "echo 'hi' | cat"])
    }

    @Test("new service: ID follows the name until edited; cwd defaults to .")
    func newService() {
        var draft = ProjectDraft.empty()
        #expect(draft.services[0].serviceId == "service")
        draft.services[0].rename("后端", taken: draft.takenIds(except: draft.services[0].id))
        #expect(draft.services[0].serviceId == "backend")
        draft.services.append(.empty(taken: draft.serviceIds))
        draft.services[1].rename("后端", taken: draft.takenIds(except: draft.services[1].id))
        #expect(draft.services[1].serviceId == "backend-2")
        draft.services[1].setServiceId("worker")
        draft.services[1].rename("任务", taken: draft.takenIds(except: draft.services[1].id))
        #expect(draft.services[1].serviceId == "worker")
        draft.services[0].cwd = "  "
        draft.services[0].commandText = "pnpm dev"
        #expect(draft.build().config.services[0].cwd == ".")
        // Loaded services never follow the name.
        var loaded = ProjectDraft(config: draft.build().config)
        loaded.services[0].rename("接口", taken: [])
        #expect(loaded.services[0].serviceId == "backend")
    }

    @Test("local errors use issue-style paths")
    func localErrors() {
        var draft = ProjectDraft(services: [
            ServiceDraft(serviceId: "api", idAuto: false, name: "", commandText: #"echo "x"#, stopTimeoutText: "0"),
            ServiceDraft(serviceId: "api", idAuto: false, name: "B", commandText: "", stopTimeoutText: "abc"),
            ServiceDraft(serviceId: "Bad_ID", idAuto: false, name: "C", commandText: "x", stopTimeoutText: "300"),
        ])
        draft.root = "relative/path"
        let e = draft.build().errors
        #expect(e["name"] == "项目名称不能为空")
        #expect(e["root"] == "根目录必须是绝对路径")
        #expect(e["services[0].name"] == "服务名称不能为空")
        #expect(e["services[0].command"] == "双引号未闭合")
        #expect(e["services[0].stopTimeoutSec"] != nil)
        #expect(e["services[1].id"] == "服务 ID 重复：api")
        #expect(e["services[1].command"] == "启动命令不能为空")
        #expect(e["services[1].stopTimeoutSec"] != nil)
        #expect(e["services[2].id"] != nil)
        #expect(e["services[2].stopTimeoutSec"] == nil, "300 is in range")
        draft.root = ""
        #expect(draft.build().errors["root"] == "根目录不能为空")
        draft.services = []
        #expect(draft.build().errors["services"] == "至少需要一个服务")
    }

    @Test("env rows: blank rows dropped, empty name and duplicates flagged, empty map omitted")
    func envRows() {
        var draft = ProjectDraft(name: "x", root: "/x", services: [
            ServiceDraft(serviceId: "a", idAuto: false, name: "A", commandText: "x"),
        ])
        draft.services[0].env = [EnvRow()]
        #expect(draft.build().config.services[0].env == nil)
        draft.services[0].env = [EnvRow(name: "", value: "v")]
        #expect(draft.build().errors["services[0].env"] == "环境变量名不能为空")
        draft.services[0].env = [EnvRow(name: "A", value: "1"), EnvRow(name: "A", value: "2")]
        #expect(draft.build().errors["services[0].env.A"] == "重复的环境变量：A")
        draft.env = [EnvRow(name: "PATH", value: "/usr/bin:/bin")]
        draft.services[0].env = []
        #expect(draft.build().config.env == ["PATH": .plain("/usr/bin:/bin")])
        #expect(draft.build().errors.isEmpty)
    }
}

@Suite("CommandPreview")
struct CommandPreviewTests {
    let params: [ParamConfig] = [
        ParamConfig(key: "profile", label: "配置", type: .enum, value: .string("dev")),
        ParamConfig(key: "apiPort", label: "端口", type: .number, value: .number(8081)),
        ParamConfig(key: "reload", label: "热重载", type: .boolean, value: .bool(true)),
        ParamConfig(key: "token", label: "令牌", type: .string, secret: true),
        ParamConfig(key: "name", label: "名字", type: .string, value: .string("it's me")),
    ]

    @Test("values substitute in place; numbers in decimal, booleans true/false")
    func values() {
        let p = CommandPreview.make(["./mvnw", "-Dprofiles=${profile}", "--port=${apiPort}", "--reload=${reload}"], params: params)
        #expect(p.argv == ["./mvnw", "-Dprofiles=dev", "--port=8081", "--reload=true"])
        #expect(p.changesAnything)
        #expect(p.unknownKeys.isEmpty)
        #expect(p.args[1].segments == [
            .init(text: "-Dprofiles=", kind: .text), .init(text: "dev", kind: .value(key: "profile")),
        ])
    }

    @Test("secret options show ••••")
    func secret() {
        let p = CommandPreview.make(["curl", "-H", "Authorization: Bearer ${token}"], params: params)
        #expect(p.argv[2] == "Authorization: Bearer ••••")
        #expect(p.args[2].segments.last?.kind == .secret(key: "token"))
    }

    @Test("unknown keys are flagged; malformed placeholders stay literal")
    func unknownAndLiteral() {
        let p = CommandPreview.make(["x", "${HOME}", "${a:-b}", "${}", "${open", "${1x}", "${port}${port}"], params: params)
        #expect(p.unknownKeys == ["HOME", "port"])
        #expect(p.argv == ["x", "${HOME}", "${a:-b}", "${}", "${open", "${1x}", "${port}${port}"])
        #expect(p.args[2].segments == [.init(text: "${a:-b}", kind: .text)])
        #expect(CommandPreview.unknownKeys(in: "http://localhost:${apiPort}/${base}", params: params) == ["base"])
    }

    @Test("$${ is a literal ${")
    func escaped() {
        let p = CommandPreview.make(["echo", "$${HOME}", "$${profile}-${profile}"], params: params)
        #expect(p.argv == ["echo", "${HOME}", "${profile}-dev"])
        #expect(p.unknownKeys.isEmpty, "an escaped key is not a reference")
        #expect(p.args[1].segments.first?.kind == .escaped)
        #expect(!CommandPreview.make(["plain"], params: params).changesAnything)
    }

    @Test("values in a shell script are single-quoted; positional args after it are not")
    func shellQuoting() {
        let p = CommandPreview.make(["/bin/zsh", "-lc", "echo ${name} ${token}", "${name}"], params: params)
        #expect(p.scriptIndex == 2)
        #expect(p.argv[2] == #"echo 'it'\''s me' '••••'"#)
        #expect(p.argv[3] == "it's me")
        #expect(CommandPreview.make(["bash", "-xc", "${name}"], params: params).argv[2] == #"'it'\''s me'"#)
        #expect(CommandPreview.make(["bash", "--rc", "${name}"], params: params).scriptIndex == nil)
        #expect(CommandPreview.make(["python3", "-c", "${name}"], params: params).argv[2] == "it's me")
        #expect(CommandPreview.make(["/bin/sh", "-c"], params: params).scriptIndex == nil)
    }
}
