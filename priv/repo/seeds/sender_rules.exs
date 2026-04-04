alias ExClaw.Repo
alias ExClaw.KnowledgeBase.EmailSender

rules = [
  # === Priority senders (from incoming_mail.py) ===
  %{match_pattern: "fource", classification_override: "business", priority_override: 5, name: "Fource"},
  %{match_pattern: "izimotive", classification_override: "business", priority_override: 5, name: "Izimotive"},
  %{email: "former-colleague@example.com", classification_override: "business", priority_override: 5, name: "Sandra Beckers"},
  %{email: "erik.vermeulen@example.be", classification_override: "business", priority_override: 5, name: "Erik Vermeulen"},
  %{match_pattern: "diana", classification_override: "personal", priority_override: 5, name: "Diana"},
  %{match_pattern: "lahdoudi", classification_override: "personal", priority_override: 5, name: "Lahdoudi"},
  %{match_pattern: "bob", classification_override: "personal", priority_override: 5, name: "Bob"},
  %{match_pattern: "spierenburg", classification_override: "personal", priority_override: 5, name: "Spierenburg"},
  %{email: "mary.elsa5@gmail.com", classification_override: "personal", priority_override: 5, name: "Mary Elsa"},
  %{match_pattern: "example-law.test", classification_override: "business", priority_override: 5, name: "VHA Legal"},
  %{match_pattern: "charlie", classification_override: "personal", priority_override: 5, name: "Charlie"},
  %{match_pattern: "smeets@vha", classification_override: "business", priority_override: 5, name: "Smeets VHA"},
  %{match_pattern: "zusterzeel", classification_override: "personal", priority_override: 5, name: "Wim Zusterzeel"},
  %{match_pattern: "example-firm.nl", classification_override: "business", priority_override: 5, name: "Smits van den Broek"},

  # === Publications/Tech (from gmail_triage.py) ===
  %{match_pattern: "changelog.com", classification_override: "newsletter", priority_override: 1, name: "Changelog"},
  %{match_pattern: "theneurondaily.com", classification_override: "newsletter", priority_override: 1, name: "The Neuron"},
  %{match_pattern: "beehiiv.com", classification_override: "newsletter", priority_override: 1, name: "Beehiiv newsletter"},
  %{match_pattern: "thenewstack.io", classification_override: "newsletter", priority_override: 1, name: "The New Stack"},
  %{match_pattern: "technologyreview.com", classification_override: "newsletter", priority_override: 1, name: "MIT Tech Review"},
  %{match_pattern: "computerworld.com", classification_override: "newsletter", priority_override: 1, name: "Computerworld"},
  %{match_pattern: "wired.com", classification_override: "newsletter", priority_override: 1, name: "Wired"},
  %{match_pattern: "venturebeat.com", classification_override: "newsletter", priority_override: 1, name: "VentureBeat"},
  %{match_pattern: "semafor.com", classification_override: "newsletter", priority_override: 1, name: "Semafor"},
  %{match_pattern: "economist.com", classification_override: "newsletter", priority_override: 1, name: "The Economist"},
  %{match_pattern: "engelsbergideas.com", classification_override: "newsletter", priority_override: 1, name: "Engelsberg Ideas"},
  %{match_pattern: "atlasobscura.com", classification_override: "newsletter", priority_override: 1, name: "Atlas Obscura"},
  %{match_pattern: "techrepublic.com", classification_override: "newsletter", priority_override: 1, name: "TechRepublic"},
  %{match_pattern: "codepen.io", classification_override: "newsletter", priority_override: 1, name: "CodePen"},
  %{match_pattern: "hubspot.com", classification_override: "newsletter", priority_override: 1, name: "HubSpot"},
  %{match_pattern: "nvidia.com", classification_override: "newsletter", priority_override: 1, name: "NVIDIA"},
  %{match_pattern: "darkreading.com", classification_override: "newsletter", priority_override: 1, name: "Dark Reading"},
  %{match_pattern: "networkcomputing.com", classification_override: "newsletter", priority_override: 1, name: "Network Computing"},
  %{match_pattern: "sciencex.com", classification_override: "newsletter", priority_override: 1, name: "ScienceX"},
  %{match_pattern: "prototypr.io", classification_override: "newsletter", priority_override: 1, name: "Prototypr"},
  %{match_pattern: "indiehackers.com", classification_override: "newsletter", priority_override: 1, name: "Indie Hackers"},
  %{match_pattern: "smartbrief.com", classification_override: "newsletter", priority_override: 1, name: "SmartBrief"},
  %{match_pattern: "uxjournal", classification_override: "newsletter", priority_override: 1, name: "UX Journal"},
  %{match_pattern: "mozilla.org", classification_override: "newsletter", priority_override: 1, name: "Mozilla"},
  %{match_pattern: "entrepreneur.com", classification_override: "newsletter", priority_override: 1, name: "Entrepreneur"},
  %{match_pattern: "quantamagazine.org", classification_override: "newsletter", priority_override: 1, name: "Quanta Magazine"},
  %{match_pattern: "science.org", classification_override: "newsletter", priority_override: 1, name: "Science AAAS"},
  %{match_pattern: "tech.eu", classification_override: "newsletter", priority_override: 1, name: "Tech.EU"},
  %{match_pattern: "thewhitebox.ai", classification_override: "newsletter", priority_override: 1, name: "The White Box"},
  %{match_pattern: "joinsuperhuman.ai", classification_override: "newsletter", priority_override: 1, name: "Superhuman AI"},
  %{match_pattern: "nytimes.com", classification_override: "newsletter", priority_override: 1, name: "NY Times"},
  %{match_pattern: "thehustle.co", classification_override: "newsletter", priority_override: 1, name: "The Hustle"},
  %{match_pattern: "readthejoe.com", classification_override: "newsletter", priority_override: 1, name: "The Joe"},
  %{match_pattern: "cnn.com", classification_override: "newsletter", priority_override: 1, name: "CNN"},
  %{match_pattern: "thenextweb.com", classification_override: "newsletter", priority_override: 1, name: "The Next Web"},
  %{match_pattern: "aitoolreport.com", classification_override: "newsletter", priority_override: 1, name: "AI Tool Report"},
  %{match_pattern: "thetechoasis.com", classification_override: "newsletter", priority_override: 1, name: "Tech Oasis"},
  %{match_pattern: "press.princeton.edu", classification_override: "newsletter", priority_override: 1, name: "Princeton UP"},
  %{match_pattern: "santafe.edu", classification_override: "newsletter", priority_override: 1, name: "Santa Fe Institute"},
  %{match_pattern: "qz.com", classification_override: "newsletter", priority_override: 1, name: "Quartz"},
  %{match_pattern: "meduza.io", classification_override: "newsletter", priority_override: 1, name: "Meduza"},
  %{match_pattern: "sitepoint.com", classification_override: "newsletter", priority_override: 1, name: "SitePoint"},
  %{match_pattern: "makeuseof.com", classification_override: "newsletter", priority_override: 1, name: "MakeUseOf"},
  %{match_pattern: "mailchimpapp.com", classification_override: "newsletter", priority_override: 1, name: "Mailchimp newsletter"},
  %{match_pattern: "dezeen.com", classification_override: "newsletter", priority_override: 1, name: "Dezeen"},
  %{match_pattern: "decorrespondent.nl", classification_override: "newsletter", priority_override: 1, name: "De Correspondent"},
  %{match_pattern: "parlement.com", classification_override: "newsletter", priority_override: 1, name: "Parlement"},
  %{match_pattern: "ghost.io", classification_override: "newsletter", priority_override: 1, name: "Ghost newsletter"},
  %{match_pattern: "mit.edu", classification_override: "newsletter", priority_override: 1, name: "MIT"},
  %{match_pattern: "bryancollins.com", classification_override: "newsletter", priority_override: 1, name: "Bryan Collins"},
  %{match_pattern: "bellingcat.com", classification_override: "newsletter", priority_override: 1, name: "Bellingcat"},
  %{match_pattern: "crewai.discoursemail.com", classification_override: "newsletter", priority_override: 1, name: "CrewAI"},
  %{match_pattern: "rasa.com", classification_override: "newsletter", priority_override: 1, name: "Rasa"},
  %{match_pattern: "stackshare.io", classification_override: "newsletter", priority_override: 1, name: "StackShare"},
  %{match_pattern: "gzeromedia.com", classification_override: "newsletter", priority_override: 1, name: "GZERO Media"},
  %{match_pattern: "eresidency", classification_override: "newsletter", priority_override: 1, name: "e-Residency"},
  %{match_pattern: "etfcoach", classification_override: "newsletter", priority_override: 1, name: "ETF Coach"},
  %{match_pattern: "thesequence", classification_override: "newsletter", priority_override: 1, name: "TheSequence"},
  %{match_pattern: "cobusgreyling", classification_override: "newsletter", priority_override: 1, name: "Cobus Greyling"},
  %{match_pattern: "superhuman_at_mail", classification_override: "newsletter", priority_override: 1, name: "Superhuman (relay)"},
  %{match_pattern: "codingbeautydev", classification_override: "newsletter", priority_override: 1, name: "Coding Beauty"},
  %{match_pattern: "headway", classification_override: "newsletter", priority_override: 1, name: "Headway"},
  %{match_pattern: "platformraam.nl", classification_override: "newsletter", priority_override: 1, name: "Platform Raam"},
  %{match_pattern: "defenseone.com", classification_override: "newsletter", priority_override: 1, name: "Defense One"},
  %{match_pattern: "aaas.sciencepubs.org", classification_override: "newsletter", priority_override: 1, name: "AAAS Science"},
  %{match_pattern: "privaterelay.appleid.com", classification_override: "newsletter", priority_override: 1, name: "Apple Relay"},
  %{match_pattern: "eoswetenschap.eu", classification_override: "newsletter", priority_override: 1, name: "EOS Wetenschap"},
  %{match_pattern: "next-mobility.de", classification_override: "newsletter", priority_override: 1, name: "Next Mobility"},
  %{match_pattern: "ayothewriter.com", classification_override: "newsletter", priority_override: 1, name: "Ayo the Writer"},
  %{match_pattern: "sdsa.ai", classification_override: "newsletter", priority_override: 1, name: "SDSA AI"},
  %{match_pattern: "elektronikpraxis.de", classification_override: "newsletter", priority_override: 1, name: "Elektronikpraxis"},
  %{match_pattern: "auto-motor-und-sport.de", classification_override: "newsletter", priority_override: 1, name: "Auto Motor Sport"},
  %{match_pattern: "getthefuturist.com", classification_override: "newsletter", priority_override: 1, name: "The Futurist"},
  %{match_pattern: "resend.com", classification_override: "newsletter", priority_override: 1, name: "Resend"},
  %{match_pattern: "ittnewsletter.com", classification_override: "newsletter", priority_override: 1, name: "ITT Newsletter"},
  %{match_pattern: "logto.io", classification_override: "newsletter", priority_override: 1, name: "Logto"},
  %{match_pattern: "email.claude.com", classification_override: "newsletter", priority_override: 1, name: "Claude/Anthropic"},
  %{match_pattern: "astronomer.io", classification_override: "newsletter", priority_override: 1, name: "Astronomer"},

  # === Substack ===
  %{match_pattern: "@substack.com", classification_override: "newsletter", priority_override: 1, name: "Substack"},

  # === Publications/Elixir ===
  %{match_pattern: "hashmerge.com", classification_override: "newsletter", priority_override: 2, name: "Elixir Weekly"},
  %{match_pattern: "elixir-lang.org", classification_override: "newsletter", priority_override: 2, name: "Elixir Lang"},
  %{match_pattern: "elixir-radar.com", classification_override: "newsletter", priority_override: 2, name: "Elixir Radar"},
  %{match_pattern: "curiosum.com", classification_override: "newsletter", priority_override: 2, name: "Curiosum"},
  %{match_pattern: "elixirforum.com", classification_override: "newsletter", priority_override: 2, name: "Elixir Forum"},

  # === Medium ===
  %{match_pattern: "@medium.com", classification_override: "newsletter", priority_override: 1, name: "Medium"},

  # === Learning ===
  %{match_pattern: "grox.io", classification_override: "newsletter", priority_override: 2, name: "Groxio (Elixir)"},
  %{match_pattern: "flaviocopes.com", classification_override: "newsletter", priority_override: 2, name: "Flavio Copes"},
  %{match_pattern: "freecodecamp.org", classification_override: "newsletter", priority_override: 2, name: "freeCodeCamp"},
  %{match_pattern: "pragprog.com", classification_override: "newsletter", priority_override: 2, name: "Pragmatic Bookstore"},
  %{match_pattern: "pragmaticstudio", classification_override: "newsletter", priority_override: 2, name: "Pragmatic Studio"},
  %{match_pattern: "scrimba.com", classification_override: "newsletter", priority_override: 2, name: "Scrimba"},
  %{match_pattern: "kirupa.com", classification_override: "newsletter", priority_override: 2, name: "Kirupa"},
  %{match_pattern: "pyimagesearch.com", classification_override: "newsletter", priority_override: 2, name: "PyImageSearch"},
  %{match_pattern: "learnopencv.com", classification_override: "newsletter", priority_override: 2, name: "LearnOpenCV"},
  %{match_pattern: "codeproject.com", classification_override: "newsletter", priority_override: 2, name: "CodeProject"},
  %{match_pattern: "londonappbrewery.com", classification_override: "newsletter", priority_override: 2, name: "London App Brewery"},

  # === Git ===
  %{match_pattern: "notifications@github.com", classification_override: "transactional", priority_override: 1, name: "GitHub notifications"},
  %{match_pattern: "noreply@github.com", classification_override: "transactional", priority_override: 1, name: "GitHub"},
  %{match_pattern: "gitlab.com", classification_override: "transactional", priority_override: 1, name: "GitLab"},

  # === Invoices ===
  %{match_pattern: "jetbrains.com", classification_override: "transactional", priority_override: 2, name: "JetBrains"},
  %{match_pattern: "ziggo.nl", classification_override: "transactional", priority_override: 2, name: "Ziggo"},
  %{match_pattern: "ziggo.com", classification_override: "transactional", priority_override: 2, name: "Ziggo"},
  %{match_pattern: "eneco.nl", classification_override: "transactional", priority_override: 2, name: "Eneco"},
  %{match_pattern: "eneco.com", classification_override: "transactional", priority_override: 2, name: "Eneco"},
  %{match_pattern: "anwb.nl", classification_override: "transactional", priority_override: 2, name: "ANWB"},
  %{match_pattern: "consumentenbond.nl", classification_override: "transactional", priority_override: 2, name: "Consumentenbond"},
  %{match_pattern: "infomedics", classification_override: "transactional", priority_override: 2, name: "Infomedics"},
  %{match_pattern: "ennatuurlijk", classification_override: "transactional", priority_override: 2, name: "Ennatuurlijk"},
  %{match_pattern: "worldstream", classification_override: "transactional", priority_override: 2, name: "Worldstream"},
  %{match_pattern: "cz.nl", classification_override: "transactional", priority_override: 2, name: "CZ"},

  # === Work ===
  %{match_pattern: "izimotive.nl", classification_override: "business", priority_override: 3, name: "Izimotive NL"},
  %{match_pattern: "izimotive.com", classification_override: "business", priority_override: 3, name: "Izimotive COM"},

  # === Unsubscribe ===
  %{match_pattern: "ourtime.com", classification_override: "spam", priority_override: 1, name: "OurTime"},
  %{match_pattern: "komoot.de", classification_override: "spam", priority_override: 1, name: "Komoot"},
  %{match_pattern: "hotel-sackmann.de", classification_override: "spam", priority_override: 1, name: "Hotel Sackmann"},
  %{match_pattern: "e-matching.nl", classification_override: "spam", priority_override: 1, name: "e-Matching"},
  %{match_pattern: "freelancer.com", classification_override: "spam", priority_override: 1, name: "Freelancer"},
  %{match_pattern: "bollants.de", classification_override: "spam", priority_override: 1, name: "Bollants"},
  %{match_pattern: "dasgesundetier.de", classification_override: "spam", priority_override: 1, name: "Das Gesunde Tier"},
  %{match_pattern: "deimann.de", classification_override: "spam", priority_override: 1, name: "Deimann"},
  %{match_pattern: "vju-ruegen.de", classification_override: "spam", priority_override: 1, name: "VJU Ruegen"},

  # === Personal ===
  %{email: "today.renee@outlook.com", classification_override: "personal", priority_override: 3, name: "Renee"},
  %{match_pattern: "idagio.com", classification_override: "personal", priority_override: 2, name: "IDAGIO"},
  %{match_pattern: "museum.nl", classification_override: "personal", priority_override: 2, name: "Museum NL"},
  %{match_pattern: "vanpiere.nl", classification_override: "personal", priority_override: 2, name: "Van Piere"},
  %{match_pattern: "apple.com", classification_override: "transactional", priority_override: 1, name: "Apple"},
  %{match_pattern: "linkedin.com", classification_override: "social", priority_override: 1, name: "LinkedIn"},
]

inserted = 0
updated = 0

for rule <- rules do
  email = rule[:email]
  domain = rule[:domain] || (email && String.split(email, "@") |> List.last())

  attrs = %{
    email: email || "rule-#{:erlang.phash2(rule.match_pattern || rule[:name])}@fast-classifier",
    domain: domain,
    name: rule[:name],
    match_pattern: rule[:match_pattern],
    classification_override: rule.classification_override,
    priority_override: rule.priority_override,
    priority_score: (rule.priority_override || 1) / 5.0,
    is_priority: (rule[:priority_override] || 0) >= 4
  }

  case Repo.get_by(EmailSender, email: attrs.email) do
    nil ->
      %EmailSender{}
      |> EmailSender.changeset(attrs)
      |> Repo.insert!()

    existing ->
      existing
      |> EmailSender.changeset(attrs)
      |> Repo.update!()
  end
end

IO.puts("Seeded #{length(rules)} sender classification rules")
