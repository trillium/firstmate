# agy scoped quota rows - resolver output

Fixture: agy rows `gemini` 0% exhausted_now, `argon` 50%, `claude_gpt` 70% (quota-axi's bare group scopes).

## Before (fork main)

```
status: escalate
reason: no rankable eligible candidate
candidate: agy:gemini-3.8-flash-high  provider=agy  -> eligible, unranked: no applicable quota row for provider agy: disclosed uncertainty
candidate: agy:gemini-4-argon  provider=agy  -> eligible, unranked: no applicable quota row for provider agy: disclosed uncertainty
candidate: agy:claude-sonnet-4-6-thinking  provider=agy  -> eligible, unranked: no applicable quota row for provider agy: disclosed uncertainty
```

## After

```
status: clear
candidate: agy:gemini-3.8-flash-high  provider=agy  scope=gemini  remaining=0%  spendPriority=-  runway=exhausted_now  -> not eligible: runway exhausted_now at gemini
candidate: agy:gemini-4-argon  provider=agy  scope=argon  remaining=50%  spendPriority=0.2  runway=through_reset  -> eligible
candidate: agy:claude-sonnet-4-6-thinking  provider=agy  scope=claude_gpt  remaining=70%  spendPriority=0.5  runway=through_reset  -> eligible
profile: --harness 'agy' --model 'claude-sonnet-4-6-thinking'
```
