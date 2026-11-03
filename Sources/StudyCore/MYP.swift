import Foundation

/// MYP defaults. Criterion *names* are the published MYP titles; level descriptors are intentionally left
/// empty so they can be filled from the student's own rubrics (nothing is invented).
public enum MYP {
    public static func criteria(for kind: SubjectKind) -> [Criterion] {
        switch kind {
        case .science:
            return [Criterion(code: "A", name: "Knowing and understanding"),
                    Criterion(code: "B", name: "Inquiring and designing"),
                    Criterion(code: "C", name: "Processing and evaluating"),
                    Criterion(code: "D", name: "Reflecting on the impacts of science")]
        case .mathematics:
            return [Criterion(code: "A", name: "Knowing and understanding"),
                    Criterion(code: "B", name: "Investigating patterns"),
                    Criterion(code: "C", name: "Communicating"),
                    Criterion(code: "D", name: "Applying mathematics in real-world contexts")]
        case .humanities:
            return [Criterion(code: "A", name: "Knowing and understanding"),
                    Criterion(code: "B", name: "Investigating"),
                    Criterion(code: "C", name: "Communicating"),
                    Criterion(code: "D", name: "Thinking critically")]
        case .language:
            return [Criterion(code: "A", name: "Analysing"),
                    Criterion(code: "B", name: "Organizing"),
                    Criterion(code: "C", name: "Producing text"),
                    Criterion(code: "D", name: "Using language")]
        case .design:
            return [Criterion(code: "A", name: "Inquiring and analysing"),
                    Criterion(code: "B", name: "Developing ideas"),
                    Criterion(code: "C", name: "Creating the solution"),
                    Criterion(code: "D", name: "Evaluating")]
        case .arts:
            return [Criterion(code: "A", name: "Knowing and understanding"),
                    Criterion(code: "B", name: "Developing skills"),
                    Criterion(code: "C", name: "Thinking creatively"),
                    Criterion(code: "D", name: "Responding")]
        case .general:
            return []
        }
    }

    /// Common command terms with short working definitions. Editable per subject; replace with the school's list.
    public static let commandTerms: [CommandTerm] = [
        CommandTerm(term: "State", definition: "Give a specific name, value or other brief answer without explanation."),
        CommandTerm(term: "Identify", definition: "Provide an answer from a number of possibilities; recognise and state briefly."),
        CommandTerm(term: "Define", definition: "Give the precise meaning of a word, phrase or physical quantity."),
        CommandTerm(term: "Describe", definition: "Give a detailed account or picture of a situation, event, pattern or process."),
        CommandTerm(term: "Outline", definition: "Give a brief account or summary."),
        CommandTerm(term: "Explain", definition: "Give a detailed account including reasons or causes."),
        CommandTerm(term: "Calculate", definition: "Obtain a numerical answer showing the relevant stages in the working."),
        CommandTerm(term: "Compare", definition: "Give an account of similarities and differences, referring to both throughout."),
        CommandTerm(term: "Analyse", definition: "Break down in order to bring out the essential elements or structure."),
        CommandTerm(term: "Discuss", definition: "Offer a considered and balanced review that includes a range of arguments, factors or hypotheses."),
        CommandTerm(term: "Evaluate", definition: "Make an appraisal by weighing up the strengths and limitations."),
        CommandTerm(term: "Justify", definition: "Give valid reasons or evidence to support an answer or conclusion."),
        CommandTerm(term: "Suggest", definition: "Propose a solution, hypothesis or other possible answer."),
        CommandTerm(term: "Sketch", definition: "Represent by means of a graph or diagram, labelled as appropriate.")
    ]

    public static func makeSubject(name: String, kind: SubjectKind) -> Subject {
        Subject(name: name, kind: kind, framework: "MYP", criteria: criteria(for: kind), commandTerms: commandTerms)
    }
}
