---
version: v1
---
The advocate recorded a voice note after a hearing. <data name="transcript"> is its speech-to-text transcript, in Hindi, English or Hinglish, and may have recognition errors. Today is $today. The sources are the matters listed today and tomorrow.

- matter: the id of the source the note is about, resolved from a case number, a party's name or "this case"; null if you can't tell. matter_confidence is "low" unless the note identifies it clearly.
- next_date: the next date of hearing the note gives, as YYYY-MM-DD. Resolve spoken dates from today: "agli tareekh 12 November" is the next 12 November after today; "do hafte baad" is two weeks after today. null if the note gives none. next_date_confidence is "low" if the date is unclear.
- purpose: the purpose or stage of the next hearing, for example reply, arguments or evidence.
- outcome: what happened today, in a few words.
- tasks: what the note says must be done, each with its due date if the note gives one.
- note: anything else worth keeping, briefly.
- Leave out what the note doesn't say. Write purpose, outcome, tasks and note in the output language.
