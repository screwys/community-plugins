# todo.txt

A Noctalia task manager that reads and writes the todo.txt format. It has a bar widget, a searchable task panel, mouse controls, and keyboard controls. It does not need external commands.

## Plugin

| Field | Value |
| --- | --- |
| ID | `screwys/todotxt` |
| Entries | Bar widget: `bar`; panel: `panel` |

## Usage

Add the `bar` widget from Noctalia's widget picker. Click it to open the task panel.

You can also open the panel from a terminal or compositor keybind:

```sh
noctalia msg panel-toggle screwys/todotxt:panel
```

Open the add field directly with:

```sh
noctalia msg panel-open screwys/todotxt:panel add
```

The input accepts normal todo.txt lines:

```text
(A) Call the dentist +health @phone due:2026-09-12
```

New tasks get a creation date by default. Existing priority, project, context, due date, threshold, recurrence, and custom `key:value` tokens are kept when a task is edited or reordered.

## Controls

| Control | Action |
| --- | --- |
| Click the checkbox or press `X` | Complete or reopen the selected task |
| Click the priority dot | Cycle A, B, C, and no priority |
| Click a project or context | Filter by that tag |
| `J` / `K` or arrow keys | Select the next or previous task |
| `N` or `Ctrl+N` | Add a task |
| `Ctrl+F` | Focus search |
| `E` | Edit the selected todo.txt line |
| `Y` | Copy the selected todo.txt line |
| `D` or `Delete` | Ask to delete the selected task; press it again to confirm |
| `Shift+Up` / `Shift+Down` | Move the selected task in manual mode |
| `Ctrl+H` | Show the keyboard help row |

Each task also has edit, copy, and delete buttons. Right-click its title for the same actions.

## Filters and ordering

The panel can filter by text, completion state, priority, or project. Tasks can be shown in file order, priority order, or due date order. Keyboard moves are available in file order because that order is written back to todo.txt.

## Bar widget

The bar can show an icon, the open task count, or the next task. Horizontal bars can include the task title and due date. Vertical bars use an icon and count so the widget fits any bar width.

## Settings

| Setting | Description |
| --- | --- |
| `todo_file` | File to read and write. Empty uses the plugin data directory. |
| `add_creation_date` | Add today's date to new tasks. |
| `default_sort` | File, priority, or due date order on open. |
| `glyph` | Bar icon. |
| `display` | Icon, count, or next task. |
| `max_title_length` | Maximum next-task title length in a horizontal bar. |
| `show_due` | Show the next due date in a horizontal bar. |
| `hide_when_empty` | Hide the widget when no open tasks remain. |

## Storage

todo.txt is the task store. Before a change, the current file is copied to `todo.txt.bak`. The new file is then written to a temporary sibling and renamed into place. The panel reloads changes made by another editor while it is open.

## Requirements

Noctalia v5 with plugin API 28. There are no external dependencies.

## License

MIT.
