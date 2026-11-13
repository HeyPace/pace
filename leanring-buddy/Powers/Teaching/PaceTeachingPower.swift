import Foundation

nonisolated enum PaceTeachingPower {
    static let definition = PacePowerDefinition(
        identifier: "pace.teaching",
        title: "Teaching",
        summary: "Explain, point, annotate and explore interactive figures alongside the user.",
        permissionsUsed: [.screenRecording],
        tools: tools,
        promptContributions: [
            .init(order: 10, applies: { $0.turnKind == .screen }, render: { _ in pointingRules }),
            .init(order: 20, applies: { $0.includeInteractiveDiagrams }, render: { _ in diagramRules }),
            .init(order: 40, applies: { $0.turnKind == .screen && $0.includeAgentMode && $0.isTuitionModeEnabled }, render: { _ in tuitionModeRules })
        ]
    )

    static let tools: [PaceLocalToolDefinition] = [
        PaceLocalToolDefinition(
            kind: .showDiagram,
            canonicalName: "show_diagram",
            aliases: ["diagram"],
            schemaExample:
                #"{"tool":"show_diagram","title":"How an airplane flies","summary":"Drag to orbit the conceptual aircraft. Select a physical part to explore it; the control slider illustrates surface movement.","nodes":[{"id":"fuselage","label":"Fuselage","detail":"The central body carries people, cargo and structural loads, joining the wings and tail."},{"id":"cockpit","label":"Flight deck","detail":"The flight deck contains controls and instruments. Pilot inputs command the aircraft control surfaces and engines."},{"id":"wings","label":"Wings","detail":"The wings produce aerodynamic lift. Their shape and angle guide the surrounding airflow; the resulting pressure distribution supports the aircraft."},{"id":"engines","label":"Engines","detail":"The engines produce forward thrust. The two underwing nacelles surround the fan and engine machinery."},{"id":"ailerons","label":"Ailerons","detail":"The outboard trailing-edge surfaces deflect in opposite directions to control roll. Select them and move the control slider."},{"id":"elevators","label":"Elevators","detail":"The horizontal-tail control surfaces change pitching moment to control nose-up and nose-down motion. Slider movement is illustrative."},{"id":"rudder","label":"Rudder","detail":"The movable trailing edge of the vertical tail controls yaw and helps coordinate turns."},{"id":"flaps","label":"Flaps","detail":"The inboard trailing-edge surfaces increase wing camber for lower-speed flight, while also increasing drag. The slider illustrates their hinged movement."}],"connections":[],"figure":{"template":"airplane","focusNodeID":"wings"}}"#,
            description:
                "generate or replace a detailed interactive figure directly over the desktop. Required: title, summary, nodes, connections. Prefer a 3D figure for physical objects: optional figure contains a trusted native template (airplane, lift_system or pi_camera), or bounded solid parts (see interactive figure rules). For 3D, nodes need stable id,label,detail and connections must be empty; bounds are optional. Optional figure.focusNodeID highlights a physical part. Optional figure.viewpoint rotates to three_quarter,side,top,front,rear,underside; omit it to preserve manual orbit. On a template with a listed moving assembly, optional figure.controlDeflection is a finite number from -1 to 1 controlling illustrative hinges; nonzero values require explicit focusNodeID for a supported moving assembly (airplane: ailerons,elevators,rudder,flaps; other templates: see catalog), and 0 returns controls to rest. For 2D flowcharts, nodes use x,y,width,height in a1000x600 canvas (width180–500,height100–300); shape rectangle/ellipse/capsule, role input/process/output/concept, subtitle optional. No overlapping 2D nodes. One to twelve explanation nodes, up to twenty-four 2D connections, each with source,target stable node IDs and optional label. Use meaningful detail for every clickable physical part. Figures stay visible across turns until dismiss_diagram. Updates replace the complete document and preserve unchanged IDs.",
            riskLevel: .readOnly,
            executionSummary:
                "Displays an interactive native diagram over the screen without changing other applications.",
            observationSummary: "The user can select a part, read its explanation, and ask Pace about it.",
            exampleUtterance: "show me a rotatable 3D airplane and explain its parts"
        ),
        PaceLocalToolDefinition(
            kind: .dismissDiagram,
            canonicalName: "dismiss_diagram",
            aliases: ["close_diagram", "hide_diagram"],
            schemaExample: #"{"tool":"dismiss_diagram"}"#,
            description: "close the current interactive diagram and all of its controls.",
            riskLevel: .readOnly,
            executionSummary: "Closes the native diagram overlay.",
            observationSummary: "No observation.",
            exampleUtterance: "close the diagram"
        ),
        PaceLocalToolDefinition(
            kind: .drawAnnotation,
            canonicalName: "draw_annotation",
            aliases: ["annotate", "draw"],
            schemaExample: #"{"tool":"draw_annotation","shapes":[{"kind":"rect","x":100,"y":80,"width":200,"height":60,"color":"red","label":"start here"}],"screen":1}"#,
            description: "draw teaching shapes on the screen overlay. shapes: rect, ellipse, line, arrow, polygon. coords are screenshot pixels (same space as click). optional color (red, blue, green, yellow, orange — default red), label (≤60 chars), strokeWidth (default 3), filled (default false). annotations persist until the next user turn or 30 seconds.",
            riskLevel: .readOnly,
            executionSummary: "Renders annotation shapes on the transparent full-screen overlay.",
            observationSummary: "No observation.",
            exampleUtterance: "draw a circle around the save button and explain it"
        ),
        PaceLocalToolDefinition(
            kind: .clearAnnotations,
            canonicalName: "clear_annotations",
            aliases: ["clear_drawing", "wipe_annotations"],
            schemaExample: #"{"tool":"clear_annotations"}"#,
            description: "remove all annotations currently drawn on the screen overlay.",
            riskLevel: .readOnly,
            executionSummary: "Clears the annotation overlay layer.",
            observationSummary: "No observation.",
            exampleUtterance: "clear the annotations"
        )
    ]

    static let pointingRules = """
    on-screen elements are given to you in this format, one per line:
        [N] role|x,y|label|text
    where N is the integer element ID. POINT and CLICK fields take ONE of those integer IDs, or -1 for "no target".

    - the x,y in the middle of the line are pixel coordinates — they are NOT element IDs. only the integer in brackets at the start of the line is the ID. do not confuse the two.
    - spokenText is what's read aloud to the user. NEVER mention element IDs, coordinates, "ID 260", or any other internal numbers — those are implementation details the user must never hear. talk like a person, not a parser.

    point ONLY when the user named a SPECIFIC target ("the save button", "the file menu", "that link"). do NOT point for general questions, descriptions, summaries, or overviews — those don't need a cursor anywhere.

    decide which case the user's request falls into:

    A. pure knowledge question OR description / summary / overview ("what's on the screen", "what does this show", "explain this", "what is html"): pointAtElementId = -1, clickElementId = -1. spokenText answers naturally. example: spokenText="this screen has a search button, a save button, and a message field."

    B. user named a target that IS in the element list. example: if the list contains `[3] button|548,40|save button|Save Draft` and the user said "click save", set pointAtElementId=3 AND clickElementId=3. if they said "where's save" without a verb, set pointAtElementId=3 and clickElementId=-1 (just point, don't click). RULE: if the user used any of these verbs — click, tap, press, open, launch, hit, choose, select — you MUST set clickElementId to the same ID as pointAtElementId. spokenText should sound natural: "opening the save button" — NOT "clicking element 3".

    C. user named a target that is NOT in the element list: pointAtElementId = -1, clickElementId = -1, spokenText names what they asked for and says you can't see it. example: spokenText="i can't see an elephant button on this screen."

    case C is critical. picking a wrong but nearby element from the list is FORBIDDEN. picking arbitrary IDs is FORBIDDEN. the only acceptable response when the target is missing is to refuse cleanly with both IDs set to -1.

    case C applies ONLY to on-screen UI elements — buttons, menus, links, fields the user pointed at. it does NOT apply to opening apps or websites. "open chrome", "launch xcode", "open hacker news", "open hacker news on chrome" are ACTIONS, not pointing targets: you open them, you do not point at them, and you do NOT need to see them on screen first. NEVER answer an open-or-launch request with "i can't see it on screen". also treat "can you open X", "could you open X", and "please open X" as direct commands to open it — do NOT reply "yes i can, would you like me to?"; just emit the open action (see agent mode below).
    """

    static let diagramRules = """
    INTERACTIVE VISUAL EXPLANATIONS
    Teach visually by default when explaining a mechanism, physical object, system, process or spatial relationship. A plain request such as "explain how a turbofan engine works" should include a useful labeled native figure without requiring the user to ask for a diagram. Present the figure early in the same response, then keep spokenText brief and tied to the highlighted part. Show how things work through recognizable geometry, purposeful detail, cutaways and anchored labels rather than a wall of text. Reuse an appropriate active figure for follow-ups; update its highlighted part or view only when it helps. Do not generate another visual for a short factual answer, arithmetic, a simple definition or an explicit text-only/one-sentence request. Prefer show_diagram for these teaching visuals so no separate image-generation round trip is needed.
    When asked for a diagram, interactive 3D model or visual explanation, create it with show_diagram. A raster image cannot rotate or expose interactive physical parts. These native figures are available even when actions and screen reading are off. The object itself should explain the subject: recognizable shapes, surfaces and meaningful parts. For a physical object, prefer a detailed rotatable 3D figure; do not substitute a flowchart of labels for a requested airplane, engine or other object. Describe the key idea in spokenText while the figure is visible. Never speak JSON or claim a figure is visible without returning its tool call.
    For a generic passenger airplane, use figure:{"template":"airplane","focusNodeID":"wings","viewpoint":"three_quarter"}, connections:[], and eight explanation nodes with exactly these IDs: fuselage,cockpit,wings,engines,ailerons,elevators,rudder,flaps. Use normal sentence case for visible diagram titles, labels and subtitles, preserving technical acronyms; the lowercase speech rule applies only to spokenText. Each node needs id,label,detail and may have a short subtitle stating its role; 2D bounds are unnecessary for 3D figures. Pace supplies a detailed native twin-engine passenger aircraft with orbit, zoom, anchored labels, selectable physical surfaces and working control-surface hinges. Label it as a conceptual aircraft, not a flight simulator or a specific certified model. For a hovering F-35B or Pi5 camera connector, use the trusted native templates listed below. For other aircraft or mechanisms, author the actual relevant structure with custom figure parts instead of relabelling this passenger aircraft. Match every explanation to the displayed physical part. Preserve an appropriate figure for follow-up questions.
    Teach with the figure itself: set focusNodeID to highlight the part being explained and its precise anchor. Optional viewpoint rotates the object to three_quarter,side,top,front,rear,underside; omit it to preserve the user's current orbit. On the airplane only, optional controlDeflection is a normalized illustrative hinge position from -1 to 1, not degrees or flight dynamics. Nonzero values require an explicit focusNodeID of ailerons,elevators,rudder or flaps to move that assembly; use 0 to return controls to rest. For example, figure:{"template":"airplane","focusNodeID":"flaps","viewpoint":"top","controlDeflection":0.6} shows the flaps from above at sixty percent of their illustrative range. Include the complete existing explanation nodes and connections:[] in every update. Keep spokenText brief and explain the motion currently shown; the user can keep rotating, selecting and moving the controls afterward. Do not claim a requested rotation or movement happened without returning its show_diagram call.
    For other objects, author figure:{"parts":[...],"focusNodeID":"..."}. A solid part has id,nodeID,geometry,position:[x,y,z],size:[width,height,depth], optional rotation:[xDegrees,yDegrees,zDegrees],finish. Geometry is box,ellipsoid,cylinder,cone,mesh. Finish is shell,metal,glass,accent,dark. Coordinates use Y up and +X as the intended front for named viewpoints; position components -12...12, size 0.005...12, rotation -360...360. Build recognizable objects with purposeful detail; use tapered mesh geometry where boxes would flatten the subject. Meshes additionally require vertices:[[x,y,z],...] in -1...1 (3–256 points) and triangles:[index,index,index,...] (at most1536 indices). Every triangle must have nonzero area. Maximum96 solids and4096 custom vertices. Each solid references one explanation node; every node must have a solid. Use at most twelve explanation nodes, group small details under their physical assembly, and keep connections:[]. No scripts, shaders, file paths or remote assets.
    Make a cutaway opening face the camera: the default side view looks toward the +Z-facing surface; adjust the opening for other viewpoints. Omit the camera-facing casing sector so opaque front walls cannot hide the shaft, blades, chambers or other functional parts. Build recognizable curved shells and tapered meshes instead of enclosing mechanisms in box walls. Group purposeful blade and fastener detail under its physical assembly; spend the existing96-solid and token budgets on the mechanism and readable negative space.
    Use a 2D flowchart only when explicitly requested or when the subject is a relationship/process that has no useful physical representation. Place nonoverlapping nodes deliberately in a1000 by600 canvas (x,y,width,height). Each connection uses source and target stable node IDs, with optional label. Use three to eight parts when possible, concise labels, and a useful local explanation in each detail field.
    Return one JSON object, without a code fence: {"spokenText":"short spoken explanation","intent":"action","payload":{"name":"show_diagram","args":{"title":"...","summary":"...","nodes":[...],"connections":[...]}}}. For follow-up edits, return a complete replacement using unchanged stable part IDs. Answers about an active figure may be plain speech if it does not need changing. Do not execute code, create files, or open a browser to draw a diagram; Pace renders the typed document natively.
    ARRAY AND TENSOR ILLUSTRATIONS
    For tokens, vectors, matrices and learning examples, use illustration:{"rows":[{"nodeID":"context","kind":"tokens","values":["the","cat","sat","on"]},{"nodeID":"target","kind":"tokens","values":["cat","sat","on","the"],"offset":1}]}. Each row references one explanation node. This native illustration replaces figure and uses connections:[]; node card coordinates are unnecessary. One to eight rows, one row per node. kind is tokens, matrix or metric. tokens/metric have up to12 values, matrices up to64, each value at most24 characters. Matrix columns are1...12. Optional token offset is0...8 and offset+cellcount must not exceed12. Use literal values that explain the user's example, with illustrative values explicitly described as such. A lesson's revealedNodeIDs reveals these rows progressively; preserve context when useful. For next-token training, y is the SAME sequence shifted one position, with the same block length as x. Every input position predicts its next target. Probability distributions and cross-entropy, not a mismatch count, drive the loss; backpropagation updates shared weights. Never label illustrative weights as measured output.
    GUIDED LESSONS
    For a multi-step explanation, include optional lesson:{"steps":[{"id":"step1","title":"...","narration":"...","revealedNodeIDs":["partID"],"focusNodeID":"partID","viewpoint":"three_quarter","controlValue":0.8,"waitForUser":false}]}. Supply one to twelve unique steps. Each narration is at most700 characters. Every revealed ID must exist in nodes, and focus must be revealed. Each step is a complete reveal snapshot; retain earlier IDs to keep earlier labels. Viewpoint and controlValue are optional. Omit viewpoint to preserve manual orbit. Play waits for actual local speech completion before advancing; manual exploration pauses. Use narration for the step explanation and keep outer spokenText empty to avoid duplicate speech. No estimated timing or arbitrary commands.
    Native detailed teaching templates are available. Prefer them for the matching subject instead of generating approximate custom geometry:
    \(PaceTeachingTemplateCatalog.prompt)
    For these templates use connections:[], all required semantic nodes, and no custom parts. They support the same focus, viewpoint and optional normalized controlDeflection on the listed moving assembly. The F-35B cutaway and Pi5 board are conceptual, not exact CAD. Do not invent dimensions or certify physical connector orientation from this model. Before camera hardware instructions, tell the user to shut down and disconnect power. The Pi5 uses22-pin connectors and a Standard-to-Mini camera cable. Describe the swivel nozzle motion as an illustration of the three-bearing mechanism.
    \(tools.first(where: { $0.canonicalName == "show_diagram" })!.promptLine)
    \(tools.first(where: { $0.canonicalName == "dismiss_diagram" })!.promptLine)
    """

    static let tuitionModeRules = """
    tuition mode is ON. the user wants you to TEACH, not DO. when they ask how to do something on screen, default to drawing + narrating instead of clicking:
    - emit a single draw_annotation tool call with the shapes that highlight the relevant element(s) — a rectangle around a button, an arrow from one place to another, an ellipse around a region.
    - narrate in spokenText what they should look at and why. one or two sentences max, written for the ear.
    - do NOT emit click, double_click, type, set_value, key, scroll, or any other tag that performs the step for them. they want to learn the step, not be flown through it.

    if the user explicitly says "just do it", "do it for me", "click it yourself", or similar, drop tuition mode for that single turn and behave like normal agent mode.

    draw_annotation shapes (all coords are screenshot pixels in the SAME space as click and POINT; include "screen": N when not the cursor screen):
    - rect:    {"kind":"rect","x":INT,"y":INT,"width":INT,"height":INT}
    - ellipse: {"kind":"ellipse","x":INT,"y":INT,"width":INT,"height":INT}    (set width==height for a circle)
    - line:    {"kind":"line","x1":INT,"y1":INT,"x2":INT,"y2":INT}
    - arrow:   {"kind":"arrow","x1":INT,"y1":INT,"x2":INT,"y2":INT}            (x1,y1 = tail, x2,y2 = head)
    - polygon: {"kind":"polygon","points":[[INT,INT], ...]}                    (closed; pentagon = 5 points)

    optional per shape: "color" (red, blue, green, yellow, orange — default red), "label" (short caption drawn near the shape, ≤60 chars), "strokeWidth" (default 3), "filled" (default false).

    annotations persist until the next user turn OR for 30 seconds, whichever comes first. you can also emit {"tool":"clear_annotations"} to wipe the layer before that — useful when moving to a new teaching moment in the same turn.

    example for "where do i save this file in textedit?":
    {
      "spokenText": "save lives in the file menu — look up here in the menu bar, then choose save.",
      "intent": "action",
      "payload": {"name":"Draw.annotation","args":{"shapes":[
        {"kind":"rect","x":18,"y":4,"width":40,"height":24,"color":"red","label":"1. file menu"},
        {"kind":"arrow","x1":58,"y1":16,"x2":120,"y2":80,"color":"red","label":"2. then save"}
      ]}}
    }
    """
}
