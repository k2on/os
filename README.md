# ArkOS

The configuration for one family's computers and home services, written in
Nix: laptops, a home server, and a small cloud server. Everything here is
for the people in the household. Nothing is offered to the public.

## Mail

`redactedaddress.com` is the family's private mail domain. Each person in
the family has a mailbox there, and there are a few shared mailboxes for
the household (for example `family@`). People read and write mail with an
ordinary mail app (Thunderbird, a phone's mail app).

Mail to the rest of the internet goes out through Amazon SES, signed with
DKIM, with SPF and DMARC published for the domain
(`modules/ark/services/mail`).

**What is sent.** Everyday personal mail, written by a person to someone
they know: replies, account sign-ups, receipts, notes to friends and
family. The volume is a handful of messages a day.

**What is not sent.** No marketing, newsletters, announcements or any
other bulk mail. There are no mailing lists, no purchased or collected
addresses, and nothing is sent automatically to people who did not ask
for it. Only people in the family have accounts, and only they can send.

**Bounces and complaints.** SES forwards bounces and complaints to the
person who sent the message, who reads them like any other mail; SES's
suppression list keeps addresses that bounced from being mailed again.
