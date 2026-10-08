// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: real passages for the Typing Test's quote mode, all in the public
/// domain (books published before 1929, and speeches and papers of the
/// United States government). Typed exactly, capitals and punctuation
/// included; dashes and quotation marks are written as the keyboard types
/// them.
struct TypingTestQuote: Equatable {
    let text: String
    let source: String

    enum Length: Int, CaseIterable {
        case any = 0, short, medium, long

        var title: String {
            switch self {
            case .any: return "all"
            case .short: return "short"
            case .medium: return "medium"
            case .long: return "long"
            }
        }
    }

    var length: Length {
        switch text.count {
        case ..<180: return .short
        case ..<320: return .medium
        default: return .long
        }
    }

    var words: [String] { text.split(separator: " ").map(String.init) }

    /// The passages of a length, all of them for `.any`.
    static func pool(_ length: Length) -> [TypingTestQuote] {
        length == .any ? all : all.filter { $0.length == length }
    }

    static let all: [TypingTestQuote] = [
        .init(text: "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife. However little known the feelings or views of such a man may be on his first entering a neighbourhood, this truth is so well fixed in the minds of the surrounding families, that he is considered the rightful property of some one or other of their daughters.",
              source: "Jane Austen, Pride and Prejudice"),
        .init(text: "Emma Woodhouse, handsome, clever, and rich, with a comfortable home and happy disposition, seemed to unite some of the best blessings of existence; and had lived nearly twenty-one years in the world with very little to distress or vex her.",
              source: "Jane Austen, Emma"),
        .init(text: "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, it was the epoch of belief, it was the epoch of incredulity, it was the season of Light, it was the season of Darkness, it was the spring of hope, it was the winter of despair.",
              source: "Charles Dickens, A Tale of Two Cities"),
        .init(text: "Marley was dead: to begin with. There is no doubt whatever about that. The register of his burial was signed by the clergyman, the clerk, the undertaker, and the chief mourner. Scrooge signed it.",
              source: "Charles Dickens, A Christmas Carol"),
        .init(text: "Call me Ishmael. Some years ago - never mind how long precisely - having little or no money in my purse, and nothing particular to interest me on shore, I thought I would sail about a little and see the watery part of the world. It is a way I have of driving off the spleen and regulating the circulation.",
              source: "Herman Melville, Moby-Dick"),
        .init(text: "Four score and seven years ago our fathers brought forth on this continent, a new nation, conceived in Liberty, and dedicated to the proposition that all men are created equal. Now we are engaged in a great civil war, testing whether that nation, or any nation so conceived and so dedicated, can long endure.",
              source: "Abraham Lincoln, the Gettysburg Address"),
        .init(text: "With malice toward none, with charity for all, with firmness in the right as God gives us to see the right, let us strive on to finish the work we are in, to bind up the nation's wounds.",
              source: "Abraham Lincoln, Second Inaugural Address"),
        .init(text: "I went to the woods because I wished to live deliberately, to front only the essential facts of life, and see if I could not learn what it had to teach, and not, when I came to die, discover that I had not lived.",
              source: "Henry David Thoreau, Walden"),
        .init(text: "The mass of men lead lives of quiet desperation. What is called resignation is confirmed desperation.",
              source: "Henry David Thoreau, Walden"),
        .init(text: "In my younger and more vulnerable years my father gave me some advice that I've been turning over in my mind ever since. \"Whenever you feel like criticizing any one,\" he told me, \"just remember that all the people in this world haven't had the advantages that you've had.\"",
              source: "F. Scott Fitzgerald, The Great Gatsby"),
        .init(text: "Gatsby believed in the green light, the orgastic future that year by year recedes before us. It eluded us then, but that's no matter - tomorrow we will run faster, stretch out our arms farther. So we beat on, boats against the current, borne back ceaselessly into the past.",
              source: "F. Scott Fitzgerald, The Great Gatsby"),
        .init(text: "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: once or twice she had peeped into the book her sister was reading, but it had no pictures or conversations in it, \"and what is the use of a book,\" thought Alice, \"without pictures or conversations?\"",
              source: "Lewis Carroll, Alice's Adventures in Wonderland"),
        .init(text: "Happy families are all alike; every unhappy family is unhappy in its own way. Everything was in confusion in the Oblonskys' house.",
              source: "Leo Tolstoy, Anna Karenina, translated by Constance Garnett"),
        .init(text: "It is a capital mistake to theorize before one has data. Insensibly one begins to twist facts to suit theories, instead of theories to suit facts.",
              source: "Arthur Conan Doyle, A Scandal in Bohemia"),
        .init(text: "A foolish consistency is the hobgoblin of little minds, adored by little statesmen and philosophers and divines. With consistency a great soul has simply nothing to do.",
              source: "Ralph Waldo Emerson, Self-Reliance"),
        .init(text: "You don't know about me without you have read a book by the name of The Adventures of Tom Sawyer; but that ain't no matter. That book was made by Mr. Mark Twain, and he told the truth, mainly.",
              source: "Mark Twain, Adventures of Huckleberry Finn"),
        .init(text: "We hold these truths to be self-evident, that all men are created equal, that they are endowed by their Creator with certain unalienable Rights, that among these are Life, Liberty and the pursuit of Happiness.",
              source: "The Declaration of Independence"),
        .init(text: "True! - nervous - very, very dreadfully nervous I had been and am; but why will you say that I am mad? The disease had sharpened my senses - not destroyed - not dulled them.",
              source: "Edgar Allan Poe, The Tell-Tale Heart"),
        .init(text: "The only way to get rid of a temptation is to yield to it. Resist it, and your soul grows sick with longing for the things it has forbidden to itself.",
              source: "Oscar Wilde, The Picture of Dorian Gray"),
        .init(text: "No one would have believed in the last years of the nineteenth century that this world was being watched keenly and closely by intelligences greater than man's and yet as mortal as his own; that as men busied themselves about their various concerns they were scrutinised and studied, perhaps almost as narrowly as a man with a microscope might scrutinise the transient creatures that swarm and multiply in a drop of water.",
              source: "H. G. Wells, The War of the Worlds"),
        .init(text: "Mrs. Dalloway said she would buy the flowers herself. For Lucy had her work cut out for her.",
              source: "Virginia Woolf, Mrs Dalloway"),
        .init(text: "Buck did not read the newspapers, or he would have known that trouble was brewing, not alone for himself, but for every tide-water dog, strong of muscle and with warm, long hair, from Puget Sound to San Diego.",
              source: "Jack London, The Call of the Wild"),
        .init(text: "So, first of all, let me assert my firm belief that the only thing we have to fear is fear itself - nameless, unreasoning, unjustified terror which paralyzes needed efforts to convert retreat into advance.",
              source: "Franklin D. Roosevelt, First Inaugural Address"),
        .init(text: "And so, my fellow Americans: ask not what your country can do for you - ask what you can do for your country. My fellow citizens of the world: ask not what America will do for you, but what together we can do for the freedom of man.",
              source: "John F. Kennedy, Inaugural Address"),
        .init(text: "There was no possibility of taking a walk that day. We had been wandering, indeed, in the leafless shrubbery an hour in the morning; but since dinner the cold winter wind had brought with it clouds so sombre, and a rain so penetrating, that further out-door exercise was now out of the question.",
              source: "Charlotte Bronte, Jane Eyre"),
        .init(text: "There is grandeur in this view of life, with its several powers, having been originally breathed into a few forms or into one; and that, whilst this planet has gone cycling on according to the fixed law of gravity, from so simple a beginning endless forms most beautiful and most wonderful have been, and are being, evolved.",
              source: "Charles Darwin, On the Origin of Species"),
        .init(text: "Stately, plump Buck Mulligan came from the stairhead, bearing a bowl of lather on which a mirror and a razor lay crossed.",
              source: "James Joyce, Ulysses"),
        .init(text: "When Mary Lennox was sent to Misselthwaite Manor to live with her uncle everybody said she was the most disagreeable-looking child ever seen. It was true, too.",
              source: "Frances Hodgson Burnett, The Secret Garden"),
        .init(text: "The most merciful thing in the world, I think, is the inability of the human mind to correlate all its contents. We live on a placid island of ignorance in the midst of black seas of infinity, and it was not meant that we should voyage far.",
              source: "H. P. Lovecraft, The Call of Cthulhu"),
        .init(text: "You can't get away from yourself by moving from one place to another. There's nothing to that.",
              source: "Ernest Hemingway, The Sun Also Rises"),
        .init(text: "To believe your own thought, to believe that what is true for you in your private heart is true for all men, - that is genius.",
              source: "Ralph Waldo Emerson, Self-Reliance"),
        .init(text: "You see, but you do not observe. The distinction is clear.",
              source: "Arthur Conan Doyle, A Scandal in Bohemia"),
    ]
}
