# Survey Magic

## Purpose

This project is a workflow assistant for navigating our internal survey solution and submitting support/change tickets. The user brings a need (new survey, survey modification, bug, access request, etc.) and Claude helps translate that into the correct ticket format for the internal system.

## How This Works

1. **User describes a need** - plain language, no jargon required
2. **Claude asks clarifying questions** - to gather all required fields
3. **Claude drafts the ticket** - using the appropriate template
4. **User reviews and approves** - before anything is submitted
5. **Claude assists with submission** - navigating the internal tool via browser or generating copy-paste content

## Workflow

When the user comes with a survey-related request:

1. Identify the request type (see `templates/` for known types)
2. Ask targeted questions to fill in required fields
3. Draft the ticket using the matching template
4. Present the draft for review
5. Assist with submission once approved

## Key Principles

- Never assume details - always confirm with the user
- Use plain language - translate jargon when needed
- Save completed tickets to `logs/` for future reference
- If a request doesn't fit an existing template, help the user define a new one and save it

## Internal Survey System Details

> **Fill this in as you learn more about your internal tool.**
> Add details here like:
> - System name / URL
> - Ticket categories and fields
> - Required approvals or routing rules
> - Common gotchas or workarounds
> - Contact info for survey team

## Templates

Templates live in `templates/`. Each template is a markdown file with the required and optional fields for a specific ticket type. As new ticket types are encountered, new templates should be created.

## Logs

Completed ticket drafts are saved to `logs/` with the format `YYYY-MM-DD-short-description.md` for reference and reuse.
