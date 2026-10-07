*** Settings ***
Documentation    The editor reads before it changes, and never changes anything unasked: Moonsplice Studio's agent,
...    judged in the words somebody would have used to ask for it. Every scenario runs against the doubles: no
...    network, no disk, no subprocess, no clock.
...
...    Converted from Gherkin (cadence@56ddad1:app/studio/agent/editor.feature), which ran under malleable. malleable
...    has been dropped, so this suite awaits the editor's move to tablua and does not run yet; its keywords are kept
...    as written so that move can implement them.
Metadata    Source    cadence@56ddad1:app/studio/agent/editor.feature
Test Tags    editor    awaits-tablua

*** Test Cases ***
it looks at the composition before it changes it
    Given the human approves change
    And the model calls holds with {}
    And the model calls change with {"edits": [{"verb": "set_prop", "node": "text1", "key": "opacity", "value": 1}], "why": "made the caption visible"}
    And the model answers "The caption is visible now."
    When the agent is asked "make the caption show up"
    Then it stops with answered
    And it calls holds before change

a change is put to the person before it lands
    Given the human approves change
    And the model calls change with {"edits": [{"verb": "set_ease", "node": "rect2", "ease": "sineOut"}], "why": "softened the bar"}
    And the model answers "Softened it."
    When the agent is asked "soften the bar"
    Then the human is asked about change
    And it stops with answered

a refusal at the gate is a result the agent reads, not an error
    Given the human refuses change
    And the model calls change with {"edits": [{"verb": "set_prop", "node": "text1", "key": "x", "value": 0}], "why": "moved the caption"}
    And the model answers "You turned that down, so nothing moved."
    When the agent is asked "put the caption on the left edge"
    Then the call to change is refused
    And it stops with answered
    And the answer says "nothing moved"

an edit the composition cannot express comes back as a sentence, not a crash
    Given the human approves change
    And the model calls change with {"edits": [{"verb": "set_prop", "node": "ghost", "key": "x", "value": 0}], "why": "moved something that is not there"}
    And the model answers "There is nothing by that name in this composition."
    When the agent is asked "move the ghost left"
    Then the call to change fails
    And it stops with answered

twelve changes for one intention are one call, so they are one undo
    Given the human approves change
    And the model calls change with {"edits": [{"verb": "set_prop", "node": "text1", "key": "x", "value": 10}, {"verb": "set_prop", "node": "rect2", "key": "x", "value": 10}], "why": "moved both to the left edge"}
    And the model answers "Both sit at the left edge now."
    When the agent is asked "line them both up on the left"
    Then it calls change 1 time
    And it notes "moved both to the left edge"

undo is put to the person too
    Given the human approves undo
    And the model calls undo with {}
    And the model answers "Put back."
    When the agent is asked "undo that"
    Then the human is asked about undo
    And it stops with answered

the pixel model never touches the composition
    Given the human approves repaint
    And the model calls repaint with {"instruction": "remove the sign on the wall"}
    And the model answers "That is new footage; the composition is unchanged."
    When the agent is asked "take the sign off the wall in the render"
    Then it calls repaint
    And it never calls change
    And the call to repaint answers "the composition is unchanged"

reading the composition asks nobody
    Given the model calls holds with {}
    And the model calls at with {"t": 1.2}
    And the model answers "The caption is invisible at 1.2 seconds."
    When the agent is asked "what is on screen at 1.2 seconds"
    Then the human is not asked
    And it stops with answered

a claim about the picture is checked against the picture
    Given the model calls shows with {}
    And the model answers "The caption sits in the left third from 0.55 seconds."
    When the agent is asked "is the caption on the left in the render"
    Then it calls shows
    And the human is not asked

putting something in is put to the person
    Given the human approves place
    And the model calls place with {"thing": "Earth night", "at": 0}
    And the model answers "Earth night is in, from the start."
    When the agent is asked "put the earth clip in"
    Then the human is asked about place
    And it stops with answered

nothing is put in over a no
    Given the human refuses place
    And the model calls place with {"thing": "Earth night"}
    And the model answers "You turned that down, so nothing went in."
    When the agent is asked "drop the earth clip in"
    Then it stops with answered
    And it never calls change

moving a clip is put to the person
    Given the human approves move_clip
    And the model calls move_clip with {"node": "Earth night", "to": 2.5}
    And the model answers "Earth night starts at 2.5 seconds now."
    When the agent is asked "move the earth clip later"
    Then the human is asked about move_clip
    And it stops with answered

trimming an end is the same verb
    Given the human approves move_clip
    And the model calls move_clip with {"node": "Earth night", "trim": "out", "at": 4}
    And the model answers "It runs to four seconds now."
    When the agent is asked "cut the end of the earth clip at four seconds"
    Then it calls move_clip
    And it stops with answered

cutting a clip in two is put to the person
    Given the human approves cut_clip
    And the model calls cut_clip with {"node": "Earth night", "at": 2}
    And the model answers "It is two clips now, joined at two seconds."
    When the agent is asked "split the earth clip at two seconds"
    Then the human is asked about cut_clip
    And it stops with answered

pinning a note to a moment is put to the person
    Given the human approves note
    And the model calls note with {"at": 41.5, "text": "the cut here is early"}
    And the model answers "Pinned it at forty-one and a half seconds."
    When the agent is asked "leave me a note where that cut is wrong, about forty seconds in"
    Then the human is asked about note
    And it stops with answered

closing the gap a clip leaves is put to the person
    Given the human approves close_gap
    And the model calls close_gap with {"node": "Line 3.2", "take_out": true}
    And the model answers "That line is out and the rest of the narration moved up to meet it."
    When the agent is asked "drop that line and close the gap"
    Then the human is asked about close_gap
    And it stops with answered

moving a thing up the stack is put to the person
    Given the human approves restack
    And the model calls restack with {"node": "rect2", "over": "text1"}
    And the model answers "The bar is in front of the caption now."
    When the agent is asked "put the bar in front of the caption"
    Then the human is asked about restack
    And it stops with answered

moving when a movement starts is put to the person
    Given the human approves move_when
    And the model calls move_when with {"node": "rect2", "at": 1.2}
    And the model answers "The bar starts moving at 1.2 seconds now."
    When the agent is asked "make the bar start moving a bit later"
    Then the human is asked about move_when
    And it stops with answered

the loop always ends
    Given the budget is 1
    And the model calls holds with {}
    When the agent is asked "keep going forever"
    Then it stops with budget

exporting is always put to the person
    Given the human refuses export
    And the model calls export with {"quality": "high"}
    And the model answers "You turned the render down."
    When the agent is asked "render it at high quality"
    Then the call to export is refused
    And nothing is written
