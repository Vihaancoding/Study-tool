import Foundation

public struct ToolSpec {
    public let name: String
    public let description: String
    public let schema: JSON
    public var apiJSON: JSON { ["name": .s(name), "description": .s(description), "input_schema": schema] }
}

private func P(_ type: String, _ desc: String, _ extra: [String: JSON] = [:]) -> JSON {
    var d: [String: JSON] = ["type": .s(type), "description": .s(desc)]
    for (k, v) in extra { d[k] = v }
    return .object(d)
}
private func S(_ props: [String: JSON], required: [String] = []) -> JSON {
    ["type": "object", "properties": .object(props), "required": .strings(required)]
}
private func arr(_ items: JSON, _ desc: String) -> JSON { P("array", desc, ["items": items]) }
private func enumP(_ values: [String], _ desc: String) -> JSON { P("string", desc, ["enum": .strings(values)]) }

public enum ToolCatalog {
    public static let actionTypes = ["add_text", "add_equation", "add_shape", "add_arrow", "add_line", "add_blank", "add_table",
                                     "add_particles", "add_timeline", "highlight", "unhighlight", "update", "move", "set_motion",
                                     "delete", "clear", "set_step", "reveal_next", "reveal_all", "hide_labels", "show_labels",
                                     "set_background", "set_title"]
    public static let questionTypes = ["single", "multi", "true_false", "short", "extended", "calculation", "equation_completion", "diagram_label"]

    public static let all: [ToolSpec] = [
        ToolSpec(name: "get_student_context",
                 description: "Read the student's saved learning profile: subjects, units/topics with mastery and spaced-repetition due dates, recurring error patterns, upcoming assessments with preparation status, recent lessons and gaps in the data. Call this at the start of a lesson and whenever you need to adapt. Only reports what is stored; if something is missing it says so — never invent it.",
                 schema: S(["subject_id": P("string", "Limit to one subject (recommended)."), "topic_id": P("string", "Focus on one topic.")])),

        ToolSpec(name: "list_curriculum",
                 description: "List a subject's criteria, command terms, units, topics (with ids and objectives) and assessments. Use these ids in other tools.",
                 schema: S(["subject_id": P("string", "Subject id.")], required: ["subject_id"])),

        ToolSpec(name: "search_sources",
                 description: "Search the student's imported notes, textbook extracts, worksheets, rubrics, feedback and past chats for relevant passages. Results carry a citation id; cite sources in your explanation as [[src:CITATION]]. Results with origin 'claude' are earlier generated notes, not original material.",
                 schema: S(["query": P("string", "Keywords to search for."), "subject_id": P("string", "Restrict to a subject."),
                            "topic_id": P("string", "Boost a topic."), "limit": P("integer", "Max results (default 5, max 10).")], required: ["query"])),

        ToolSpec(name: "read_source",
                 description: "Read a stored resource in full (paged by chunk). Use after search_sources when you need more context, e.g. to read a rubric or an assessment brief.",
                 schema: S(["resource_id": P("string", "Resource id."), "from_chunk": P("integer", "First chunk index (default 0)."),
                            "max_chunks": P("integer", "How many chunks (default 4, max 8).")], required: ["resource_id"])),

        ToolSpec(name: "get_mistakes",
                 description: "Retrieve the student's saved mistake log (question, their answer, correct reasoning, category, topic, follow-up results). Use to target teaching and to build retest questions (pass the mistake id as tests_mistake_id in create_quiz).",
                 schema: S(["subject_id": P("string", "Subject id."), "topic_id": P("string", "Topic id."),
                            "category": enumP(ErrorCategory.allCases.map { $0.rawValue }, "Error category."),
                            "only_unresolved": P("boolean", "Default true."), "limit": P("integer", "Default 10, max 30.")])),

        ToolSpec(name: "open_lesson",
                 description: "Set the title, topic and learning objectives of the current lesson and focus the classroom on it. The app already created the lesson when the student started it; call this once after reading their context to state what this session will cover.",
                 schema: S(["title": P("string", "Short lesson title."), "topic_id": P("string", "Topic id this lesson covers (optional)."),
                            "objectives": arr(P("string", "A learning objective."), "2-4 objectives for this session.")], required: ["title"])),

        ToolSpec(name: "whiteboard_apply",
                 description: "Draw on and manipulate the live whiteboard. Takes a batch of structured actions that are validated together and applied atomically (if any action is invalid NOTHING is applied and you get the reason). Coordinates are board units (origin top-left, x right, y down; the visible area is roughly 1400x850). Give objects a 'name' so you can refer to them later. Use 'step' on objects to reveal them progressively (objects with step N appear when the board's current step >= N; use reveal_next/set_step to advance). Action types and fields: add_text{text,x,y,size?,color?,bold?}; add_equation{text (LaTeX-like, e.g. 2x^2+3x=5),x,y,size?}; add_shape{shape:rect|ellipse|diamond|triangle,x,y,w,h,text?,fill?}; add_arrow{x1,y1,x2,y2,label?,head?}; add_line{x1,y1,x2,y2}; add_blank{x,y,w?,h?,prompt?,expected?} (an empty box the student fills in; read it back with whiteboard_read); add_table{x,y,rows:[[...]],cell_w?,cell_h?,header?}; add_particles{x,y,w,h,count,state:solid|liquid|gas,radius?,name_prefix?} (animated particle model in a container); add_timeline{x,y,w?,events:[{label,detail?}],reveal_sequentially?}; highlight{ref|refs|region:{x,y,w,h}}; unhighlight{ref|refs|all}; update{ref,text?,color?,fill?,size?,step?,hidden?,x?,y?,w?,h?}; move{ref,x,y} (animated); set_motion{ref,motion:none|jiggle|drift,amplitude?,speed?}; delete{ref|refs}; clear; set_step{step}; reveal_next; reveal_all; hide_labels{refs|group|all_text:true} (recall mode: labels become hidden boxes the student must reconstruct); show_labels{...}; set_background{background:grid|plain|lines}; set_title{title}. Common optional fields on add_*: name, step, group, color, dashed, stroke_width.",
                 schema: S(["actions": arr(["type": "object",
                                            "properties": ["type": enumP(actionTypes, "Action type.")],
                                            "required": ["type"]], "Ordered list of actions (1-120)."),
                            "board_id": P("string", "Board to act on. Defaults to the current lesson's board.")], required: ["actions"])),

        ToolSpec(name: "whiteboard_read",
                 description: "Read the current board state, including anything the student changed: text they typed into blank boxes (student_answer), guesses on hidden labels, objects they drew or moved. Also returns a picture of the board so you can see freehand drawing. Call before reacting to the student's board work.",
                 schema: S(["board_id": P("string", "Defaults to the current lesson's board.")])),

        ToolSpec(name: "create_quiz",
                 description: "Create and (by default) launch a real interactive quiz in the app. Objective questions (single, multi, true_false, calculation, equation_completion, diagram_label, short with accepted answers/keywords) are marked automatically on submit; extended answers and anything needing judgement are returned to you to mark with mark_response. Provide answer keys, model answers and rubrics so marking is traceable to the source material. Question fields — common: type, prompt, marks?, hint?, topic_id?, criterion? (e.g. 'B'), command_term?, model_answer?, rubric?, source_refs?, tests_mistake_id?, difficulty?(1-3). single: options[], correct:[index]. multi: options[], correct:[indices]. true_false: correct_answer:true|false. short: acceptable_answers[] and/or keywords[]. extended: rubric and/or model_answer. calculation: answer(number), tolerance_percent?, unit?, unit_alternatives?, sig_figs?, require_working?. equation_completion: prompt containing ___ for each blank, blanks:[answers]. diagram_label: board_id (a board showing the unlabeled diagram), labels:[{x,y,answer,acceptable?}] positions in board coordinates, label_bank? (list of options).",
                 schema: S(["subject_id": P("string", "Subject id."), "title": P("string", "Quiz title."),
                            "mode": enumP(QuizMode.allCases.map { $0.rawValue }, "practice | timed | exam | retrieval | adaptive | quick"),
                            "time_limit_minutes": P("integer", "Required for timed/exam modes (1-180)."),
                            "launch": P("boolean", "Open the quiz for the student immediately (default true)."),
                            "questions": arr(["type": "object",
                                              "properties": ["type": enumP(questionTypes, "Question type."), "prompt": P("string", "Question text.")],
                                              "required": ["type", "prompt"]], "1-40 questions.")],
                        required: ["subject_id", "title", "questions"])),

        ToolSpec(name: "get_quiz_results",
                 description: "Read the student's submitted answers for a quiz, with each question's prompt, their answer, working, hints used, answer key/rubric and the current auto-marks. Questions with status 'needs_your_marking' are waiting for you. If the student has not submitted yet it says so — do not guess their answers.",
                 schema: S(["quiz_id": P("string", "Quiz id (defaults to the most recent quiz in this lesson)."), "attempt_id": P("string", "A specific attempt.")])),

        ToolSpec(name: "mark_response",
                 description: "Record your marks and feedback for questions in a submitted attempt (required for extended responses, and for short answers/calculation working that were flagged). Award partial credit where justified, in 0.5 steps. Always give feedback that explains lost marks, a better answer, error_categories for lost marks, and — for rubric/subjective judgements — an honest 'uncertainty' note. When every question is marked the app finalises the attempt: it logs mistakes, updates topic mastery and reschedules spaced repetition.",
                 schema: S(["attempt_id": P("string", "Attempt id from get_quiz_results."),
                            "marks": arr(["type": "object",
                                          "properties": ["question_id": P("string", "Question id."), "awarded": P("number", "Marks awarded (0..max)."),
                                                         "feedback": P("string", "Why marks were gained/lost, referring to the student's actual words."),
                                                         "better_answer": P("string", "A model improved answer."),
                                                         "error_categories": arr(enumP(ErrorCategory.allCases.map { $0.rawValue }, "Category."), "Required when marks are lost."),
                                                         "criterion": P("string", "MYP criterion code this evidences, e.g. 'A'."),
                                                         "uncertainty": P("string", "Where the mark is a judgement call, say so.")],
                                          "required": ["question_id", "awarded", "feedback"]], "Marks per question.")],
                        required: ["attempt_id", "marks"])),

        ToolSpec(name: "log_mistake",
                 description: "Save a mistake the student made OUTSIDE a quiz (in discussion, on the board, in worked problems) to the searchable error log. Quiz mistakes are logged automatically; do not duplicate them.",
                 schema: S(["subject_id": P("string", "Subject id."), "topic_id": P("string", "Topic id."),
                            "question": P("string", "What they were asked to do."), "student_answer": P("string", "What they actually said/wrote."),
                            "correct_reasoning": P("string", "The correct reasoning."),
                            "category": enumP(ErrorCategory.allCases.map { $0.rawValue }, "Error category."),
                            "criterion": P("string", "MYP criterion code, if relevant.")],
                        required: ["subject_id", "question", "student_answer", "correct_reasoning", "category"])),

        ToolSpec(name: "record_understanding",
                 description: "Record your evidence-based judgement of the student's understanding of a topic from this conversation (not from quizzes, which are recorded automatically). Be conservative: 'secure' only if they explained and applied it unaided. This feeds spaced repetition with low weight.",
                 schema: S(["topic_id": P("string", "Topic id."), "level": enumP(["none", "partial", "secure"], "Observed understanding."),
                            "evidence": P("string", "Specific things the student said or did.")], required: ["topic_id", "level", "evidence"])),

        ToolSpec(name: "schedule_review",
                 description: "Schedule a revision session for a topic. Sets the topic's spaced-repetition due date and (optionally) a native macOS reminder. Use after teaching: sooner for shaky topics (1-2 days), later for solid ones.",
                 schema: S(["topic_id": P("string", "Topic id."), "in_days": P("integer", "0-120 days from now."),
                            "note": P("string", "What to practise."), "notify": P("boolean", "Send a notification (default true).")],
                        required: ["topic_id", "in_days"])),

        ToolSpec(name: "curriculum_add",
                 description: "Add units, topics (with objectives) and assessments to the student's curriculum, e.g. when organising imported syllabus material. Only add what is supported by the student's sources or what they told you; set source_refs to resource ids/citations. Do not invent dates or grades.",
                 schema: S(["items": arr(["type": "object",
                                          "properties": ["kind": enumP(["unit", "topic", "assessment"], "What to add."), "subject_id": P("string", "Subject id."),
                                                         "title": P("string", "Title."), "unit_id": P("string", "Topic: existing unit id."),
                                                         "unit_title": P("string", "Topic: unit title (created if needed)."),
                                                         "summary": P("string", "Topic summary."),
                                                         "objectives": arr(["type": "object", "properties": ["text": P("string", "Objective."), "criterion": P("string", "Criterion code.")], "required": ["text"]], "Topic objectives."),
                                                         "source_refs": arr(P("string", "Resource id or citation."), "Evidence."),
                                                         "date": P("string", "Assessment date, YYYY-MM-DD, only if stated in the sources."),
                                                         "criteria": arr(P("string", "Criterion code."), "Assessment criteria."),
                                                         "topic_titles": arr(P("string", "Topic title."), "Assessment topics (existing).")],
                                          "required": ["kind", "subject_id", "title"]], "1-60 items.")], required: ["items"])),

        ToolSpec(name: "save_note",
                 description: "Save a concise study note you wrote (summary, worked example, mnemonic) to the subject's resources. It is stored as generated material, clearly separate from the student's original sources.",
                 schema: S(["subject_id": P("string", "Subject id."), "topic_id": P("string", "Topic id."), "title": P("string", "Note title."), "text": P("string", "Note body.")],
                        required: ["subject_id", "title", "text"])),

        ToolSpec(name: "end_lesson",
                 description: "Finish the current lesson: saves your summary, topics covered and next steps. Call when the student is done or asks to wrap up, after scheduling reviews.",
                 schema: S(["summary": P("string", "2-5 sentence summary of what was covered and how the student did."),
                            "topics_covered": arr(P("string", "Topic id."), "Topics touched."),
                            "next_steps": arr(P("string", "A concrete next step."), "What to do next time.")], required: ["summary"]))
    ]

    public static var apiJSON: [JSON] { all.map { $0.apiJSON } }
}
