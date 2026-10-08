// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: code for the Typing Test's code mode. Short snippets written for
/// Vorssaint, kept with their lines and indentation and colored the way an
/// editor colors them. Only the words are typed: indentation comes by
/// itself, and Space or Return moves on from a word at the end of a line.
enum TypingTestLanguage: Int, CaseIterable {
    // Raw values are saved; new languages go at the end.
    case swift = 1, python, javascript, go, rust, typescript, react, sql

    /// The order the language menu lists them in.
    static let menuOrder: [TypingTestLanguage] = [.python, .typescript, .react, .rust, .go, .sql, .javascript, .swift]

    var title: String {
        switch self {
        case .swift: return "Swift"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .go: return "Go"
        case .rust: return "Rust"
        case .typescript: return "TypeScript"
        case .react: return "React"
        case .sql: return "SQL"
        }
    }

    /// How the mode bar names it.
    var shortTitle: String {
        switch self {
        case .javascript: return "js"
        case .typescript: return "ts"
        default: return title.lowercased()
        }
    }

    var lineComment: String {
        switch self {
        case .python: return "#"
        case .sql: return "--"
        default: return "//"
        }
    }

    /// SQL keywords are matched in any case.
    var caseInsensitiveKeywords: Bool { self == .sql }

    /// Characters that open a string; Rust's ' also starts a lifetime, so
    /// it is left out there.
    var stringQuotes: Set<Character> {
        switch self {
        case .swift, .go: return ["\""]
        case .python: return ["\"", "'"]
        case .javascript, .typescript, .react: return ["\"", "'", "`"]
        case .rust: return ["\""]
        case .sql: return ["'"]
        }
    }

    private static let javascriptKeywords: Set<String> = [
        "function", "const", "let", "var", "return", "if", "else", "for", "of", "in", "while",
        "class", "new", "this", "async", "await", "throw", "try", "catch", "import", "export",
        "from", "default", "true", "false", "null", "undefined", "typeof"]

    var keywords: Set<String> {
        switch self {
        case .swift:
            return ["func", "var", "let", "if", "else", "for", "in", "while", "return", "struct", "class",
                    "enum", "case", "switch", "default", "import", "self", "Self", "nil", "true", "false",
                    "try", "await", "async", "throws", "guard", "extension", "protocol", "static", "private",
                    "public", "init", "where", "some", "inout", "break", "continue", "do", "catch"]
        case .python:
            return ["def", "class", "return", "if", "elif", "else", "for", "in", "while", "import", "from",
                    "as", "with", "yield", "lambda", "None", "True", "False", "and", "or", "not", "is",
                    "try", "except", "raise", "pass", "self", "print", "async", "await"]
        case .javascript:
            return Self.javascriptKeywords
        case .typescript, .react:
            return Self.javascriptKeywords.union([
                "interface", "type", "enum", "implements", "extends", "readonly", "private", "public",
                "protected", "as", "keyof", "number", "string", "boolean", "void", "unknown", "any", "never",
                "switch", "case"])
        case .sql:
            return ["SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "ON", "GROUP", "BY",
                    "ORDER", "HAVING", "LIMIT", "AS", "AND", "OR", "NOT", "IN", "IS", "NULL", "INSERT", "INTO",
                    "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "PRIMARY", "KEY", "REFERENCES",
                    "INDEX", "WITH", "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END", "DESC", "ASC", "OVER",
                    "PARTITION", "INTEGER", "TEXT", "TIMESTAMP", "DEFAULT", "UNIQUE", "TRUE", "FALSE", "BETWEEN",
                    "LIKE", "UNION", "ALL", "EXISTS"]
        case .go:
            return ["func", "var", "const", "type", "struct", "interface", "return", "if", "else", "for",
                    "range", "package", "import", "go", "chan", "map", "nil", "true", "false", "defer",
                    "switch", "case", "default", "string", "int", "float64", "bool", "rune", "byte", "error",
                    "len", "make"]
        case .rust:
            return ["fn", "let", "mut", "if", "else", "for", "in", "while", "loop", "match", "return",
                    "struct", "enum", "impl", "trait", "use", "pub", "self", "Self", "true", "false", "where",
                    "mod", "const", "static", "as", "ref", "move", "f64", "i32", "u32", "usize", "str",
                    "bool"]
        }
    }
}

/// What a character of code is, for its color.
enum TypingTestSyntax: Equatable {
    case plain, keyword, string, comment, number, type, function, punctuation
}

struct TypingTestCodeSnippet: Equatable {
    struct Line: Equatable {
        /// Spaces before the first word.
        var indent: Int
        /// The run's word indexes on this line; empty for a blank line.
        var words: Range<Int>
    }

    let language: TypingTestLanguage
    let title: String
    let text: String
    /// Every word in order, as typed.
    let words: [String]
    let lines: [Line]
    /// The color of each letter of each word.
    let syntax: [[TypingTestSyntax]]

    init(_ language: TypingTestLanguage, _ title: String, _ text: String) {
        self.language = language
        self.title = title
        self.text = text
        var words: [String] = [], lines: [Line] = [], syntax: [[TypingTestSyntax]] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let indent = line.prefix { $0 == " " }.count
            let classes = Self.highlight(line, language)
            let start = words.count
            var offset = indent
            for word in line.dropFirst(indent).split(separator: " ") {
                words.append(String(word))
                syntax.append(Array(classes[offset..<(offset + word.count)]))
                offset += word.count + 1
            }
            lines.append(Line(indent: indent, words: start..<words.count))
        }
        self.words = words
        self.lines = lines
        self.syntax = syntax
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.language == rhs.language && lhs.text == rhs.text }

    var source: String { "\(language.title) · \(title)" }

    /// The widest line, in characters, for fitting the font to the window.
    var columns: Int {
        text.split(separator: "\n").map(\.count).max() ?? 0
    }

    /// The line a word is on.
    func line(of word: Int) -> Int {
        lines.firstIndex { $0.words.contains(word) } ?? max(0, lines.count - 1)
    }

    // MARK: Highlighting

    /// A color for every character of one line, the way an editor would:
    /// comments, strings, numbers, keywords, types (capitalized), calls
    /// (a name before "("), and punctuation.
    static func highlight(_ line: String, _ language: TypingTestLanguage) -> [TypingTestSyntax] {
        let characters = Array(line)
        var result = [TypingTestSyntax](repeating: .plain, count: characters.count)
        let comment = Array(language.lineComment)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if characters[index...].starts(with: comment) {
                for rest in index..<characters.count { result[rest] = .comment }
                break
            }
            if language.stringQuotes.contains(character) {
                var end = index + 1
                while end < characters.count, characters[end] != character {
                    end += characters[end] == "\\" ? 2 : 1
                }
                end = min(end, characters.count - 1)
                for position in index...end { result[position] = .string }
                index = end + 1
                continue
            }
            if character.isNumber, index == 0 || !(characters[index - 1].isLetter || characters[index - 1] == "_") {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." { end += 1 }
                for position in index..<end { result[position] = .number }
                index = end
                continue
            }
            if character.isLetter || character == "_" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber
                        || characters[end] == "_" { end += 1 }
                let name = String(characters[index..<end])
                let kind: TypingTestSyntax
                // A JSX tag: a name right after < or </.
                let isTag = language == .react && index > 0
                    && (characters[index - 1] == "<" || index > 1 && characters[index - 1] == "/" && characters[index - 2] == "<")
                if language.keywords.contains(language.caseInsensitiveKeywords ? name.uppercased() : name) {
                    kind = .keyword
                } else if isTag {
                    kind = .type
                } else if end < characters.count, characters[end] == "(" || characters[end] == "!" && language == .rust {
                    kind = .function
                } else if character.isUppercase, language != .sql {
                    kind = .type
                } else {
                    kind = .plain
                }
                for position in index..<end { result[position] = kind }
                index = end
                continue
            }
            if !character.isWhitespace { result[index] = .punctuation }
            index += 1
        }
        return result
    }

    // MARK: The snippets

    /// The snippets of one language, or all of them.
    static func pool(_ language: TypingTestLanguage?) -> [TypingTestCodeSnippet] {
        guard let language else { return all }
        return all.filter { $0.language == language }
    }

    static let all: [TypingTestCodeSnippet] = [
        .init(.swift, "binary search", """
        func binarySearch(_ items: [Int], for target: Int) -> Int? {
            var low = 0
            var high = items.count - 1
            while low <= high {
                let mid = (low + high) / 2
                if items[mid] == target { return mid }
                if items[mid] < target {
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return nil
        }
        """),
        .init(.swift, "computed properties", """
        struct Temperature {
            var celsius: Double

            var fahrenheit: Double {
                celsius * 9 / 5 + 32
            }

            // Anything at or below zero freezes water.
            var isFreezing: Bool { celsius <= 0 }
        }
        """),
        .init(.swift, "async loading", """
        func loadUser(id: String) async throws -> User {
            let url = URL(string: "https://example.com/users/\\(id)")!
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(User.self, from: data)
        }
        """),
        .init(.swift, "enums", """
        enum Direction {
            case north, south, east, west

            var opposite: Direction {
                switch self {
                case .north: return .south
                case .south: return .north
                case .east: return .west
                case .west: return .east
                }
            }
        }
        """),
        .init(.python, "word counts", """
        def word_counts(text):
            counts = {}
            for word in text.lower().split():
                counts[word] = counts.get(word, 0) + 1
            return counts
        """),
        .init(.python, "a stack", """
        class Stack:
            def __init__(self):
                self.items = []

            def push(self, item):
                self.items.append(item)

            def pop(self):
                # Raises IndexError when empty.
                return self.items.pop()
        """),
        .init(.python, "reading json", """
        import json

        def active_names(path):
            with open(path) as file:
                people = json.load(file)
            return [p["name"] for p in people if p.get("active")]
        """),
        .init(.python, "generators", """
        def fibonacci(limit):
            a, b = 0, 1
            while a < limit:
                yield a
                a, b = b, a + b

        print(list(fibonacci(100)))
        """),
        .init(.python, "dataclasses", """
        from dataclasses import dataclass, field

        @dataclass
        class Order:
            id: int
            items: list[str] = field(default_factory=list)

            @property
            def is_empty(self) -> bool:
                return not self.items
        """),
        .init(.python, "asyncio", """
        import asyncio

        async def fetch_all(urls, fetch):
            tasks = [fetch(url) for url in urls]
            return await asyncio.gather(*tasks)

        results = asyncio.run(fetch_all(["a", "b"], fake_fetch))
        """),
        .init(.javascript, "debounce", """
        function debounce(fn, delay) {
          let timer;
          return (...args) => {
            clearTimeout(timer);
            timer = setTimeout(() => fn(...args), delay);
          };
        }
        """),
        .init(.javascript, "fetching", """
        async function getRepos(user) {
          const response = await fetch(`/api/users/${user}/repos`);
          if (!response.ok) {
            throw new Error(`Request failed: ${response.status}`);
          }
          return response.json();
        }
        """),
        .init(.javascript, "array methods", """
        const total = orders
          .filter((order) => order.paid)
          .map((order) => order.amount)
          .reduce((sum, amount) => sum + amount, 0);

        console.log(`Total: ${total.toFixed(2)}`);
        """),
        .init(.javascript, "private fields", """
        class Counter {
          #count = 0;

          increment() {
            this.#count += 1;
            return this.#count;
          }
        }
        """),
        .init(.typescript, "interfaces", """
        interface User {
          id: number;
          name: string;
          email?: string;
        }

        function greet(user: User): string {
          return `Hello, ${user.name}!`;
        }
        """),
        .init(.typescript, "generics", """
        function groupBy<T, K extends string>(items: T[], key: (item: T) => K) {
          const groups = {} as Record<K, T[]>;
          for (const item of items) {
            (groups[key(item)] ??= []).push(item);
          }
          return groups;
        }
        """),
        .init(.typescript, "union types", """
        type Result<T> =
          | { ok: true; value: T }
          | { ok: false; error: string };

        function unwrap<T>(result: Result<T>): T {
          if (!result.ok) throw new Error(result.error);
          return result.value;
        }
        """),
        .init(.typescript, "a typed cache", """
        class Cache<V> {
          private store = new Map<string, V>();

          get(key: string): V | undefined {
            return this.store.get(key);
          }

          set(key: string, value: V): void {
            this.store.set(key, value);
          }
        }
        """),
        .init(.typescript, "enums", """
        enum Status {
          Active = "active",
          Paused = "paused",
        }

        const label = (status: Status): string => {
          switch (status) {
            case Status.Active:
              return "Running";
            case Status.Paused:
              return "On hold";
          }
        };
        """),
        .init(.react, "a counter", """
        import { useState } from "react";

        export function Counter() {
          const [count, setCount] = useState(0);
          return (
            <button onClick={() => setCount(count + 1)}>
              Clicked {count} times
            </button>
          );
        }
        """),
        .init(.react, "rendering a list", """
        type Todo = { id: number; title: string; done: boolean };

        export function TodoList({ todos }: { todos: Todo[] }) {
          return (
            <ul>
              {todos.map((todo) => (
                <li key={todo.id} className={todo.done ? "done" : ""}>
                  {todo.title}
                </li>
              ))}
            </ul>
          );
        }
        """),
        .init(.react, "a data hook", """
        function useUser(id: string) {
          const [user, setUser] = useState<User | null>(null);

          useEffect(() => {
            fetch(`/api/users/${id}`)
              .then((res) => res.json())
              .then(setUser);
          }, [id]);

          return user;
        }
        """),
        .init(.react, "a controlled form", """
        type SearchProps = { onSearch: (query: string) => void };

        export function Search({ onSearch }: SearchProps) {
          const [query, setQuery] = useState("");
          return (
            <form onSubmit={(e) => { e.preventDefault(); onSearch(query); }}>
              <input value={query} onChange={(e) => setQuery(e.target.value)} />
            </form>
          );
        }
        """),
        .init(.react, "children", """
        type CardProps = {
          title: string;
          children: React.ReactNode;
        };

        export const Card = ({ title, children }: CardProps) => (
          <section className="card">
            <h2>{title}</h2>
            {children}
          </section>
        );
        """),
        .init(.go, "reversing a string", """
        func reverse(s string) string {
            runes := []rune(s)
            for i, j := 0, len(runes)-1; i < j; i, j = i+1, j-1 {
                runes[i], runes[j] = runes[j], runes[i]
            }
            return string(runes)
        }
        """),
        .init(.go, "a health check", """
        func health(w http.ResponseWriter, r *http.Request) {
            w.Header().Set("Content-Type", "application/json")
            json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
        }
        """),
        .init(.go, "methods", """
        type Rectangle struct {
            Width, Height float64
        }

        func (r Rectangle) Area() float64 {
            return r.Width * r.Height
        }
        """),
        .init(.go, "channels", """
        func sum(numbers []int, out chan<- int) {
            total := 0
            for _, n := range numbers {
                total += n
            }
            out <- total
        }
        """),
        .init(.go, "errors", """
        func divide(a, b float64) (float64, error) {
            if b == 0 {
                return 0, errors.New("division by zero")
            }
            return a / b, nil
        }
        """),
        .init(.go, "counting words", """
        func topWord(text string) string {
            counts := map[string]int{}
            best := ""
            for _, word := range strings.Fields(text) {
                counts[word]++
                if counts[word] > counts[best] {
                    best = word
                }
            }
            return best
        }
        """),
        .init(.rust, "generics", """
        fn largest<T: PartialOrd>(list: &[T]) -> &T {
            let mut largest = &list[0];
            for item in list {
                if item > largest {
                    largest = item;
                }
            }
            largest
        }
        """),
        .init(.rust, "structs", """
        #[derive(Debug)]
        struct Point {
            x: f64,
            y: f64,
        }

        impl Point {
            fn length(&self) -> f64 {
                (self.x * self.x + self.y * self.y).sqrt()
            }
        }
        """),
        .init(.rust, "match", """
        fn describe(n: i32) -> &'static str {
            match n {
                0 => "zero",
                x if x < 0 => "negative",
                _ => "positive",
            }
        }
        """),
        .init(.rust, "errors", """
        use std::fs;

        fn read_config(path: &str) -> Result<String, std::io::Error> {
            let text = fs::read_to_string(path)?;
            Ok(text.trim().to_string())
        }
        """),
        .init(.rust, "enums with data", """
        enum Shape {
            Circle(f64),
            Square(f64),
        }

        impl Shape {
            fn area(&self) -> f64 {
                match self {
                    Shape::Circle(r) => std::f64::consts::PI * r * r,
                    Shape::Square(side) => side * side,
                }
            }
        }
        """),
        .init(.rust, "iterators", """
        fn main() {
            let words = vec!["level", "rust", "kayak", "go"];
            let palindromes: Vec<&str> = words
                .into_iter()
                .filter(|w| w.chars().eq(w.chars().rev()))
                .collect();
            println!("{:?}", palindromes);
        }
        """),
        .init(.sql, "a simple query", """
        SELECT name, email
        FROM users
        WHERE created_at >= '2026-01-01'
        ORDER BY name ASC
        LIMIT 20;
        """),
        .init(.sql, "joins and groups", """
        SELECT c.name, COUNT(o.id) AS orders, SUM(o.total) AS spent
        FROM customers c
        LEFT JOIN orders o ON o.customer_id = c.id
        GROUP BY c.name
        HAVING COUNT(o.id) > 3
        ORDER BY spent DESC;
        """),
        .init(.sql, "creating a table", """
        CREATE TABLE posts (
            id INTEGER PRIMARY KEY,
            author_id INTEGER NOT NULL REFERENCES users(id),
            title TEXT NOT NULL,
            published_at TIMESTAMP
        );
        """),
        .init(.sql, "window functions", """
        WITH ranked AS (
            SELECT team, player, score,
                ROW_NUMBER() OVER (
                    PARTITION BY team ORDER BY score DESC
                ) AS rank
            FROM results
        )
        SELECT team, player, score
        FROM ranked
        WHERE rank = 1;
        """),
        .init(.sql, "changing rows", """
        INSERT INTO tags (name)
        VALUES ('swift'), ('rust'), ('go');

        UPDATE posts
        SET title = 'Hello, world'
        WHERE id = 42;

        -- Drafts were never published.
        DELETE FROM posts WHERE published_at IS NULL;
        """),
    ]
}
