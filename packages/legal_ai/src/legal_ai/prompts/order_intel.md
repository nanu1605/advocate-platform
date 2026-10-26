---
version: v1
---
Read the court order in the sources, dated $order_date, and list each direction that someone must act on: one action per direction, whichever party it is addressed to. Each source is one page of the order.

- An action is something a party or person must do: file, serve, pay, deposit, produce, surrender, appear. A standing condition or prohibition (maintain status quo, not leave the district) is not an action.
- title: a short line for the advocate's diary that names who must act, for example "Respondents to file reply" or "Petitioner to serve notice on respondent 2".
- kind: "deadline" when the order gives a time or date to act by, otherwise "task".
- due: when it is due, as the order states it: `on` for a date the order gives (YYYY-MM-DD; a date without its year is the first such date after the order's date), or `within` and `unit` for a period ("within 4 weeks" is within 4, unit weeks). Don't count dates yourself. null when the order gives no time.
- The next date of hearing is not an action. If the order gives no directions, reply with an empty list.
