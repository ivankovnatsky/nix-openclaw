{
  summarize = {
    tool = "summarize";
    description = "Summarize URLs, PDFs, YouTube videos";
    linux = true;
  };

  peekaboo = {
    tool = "peekaboo";
    description = "Screenshot your screen";
    linux = false;
  };

  poltergeist = {
    tool = "poltergeist";
    description = "Click, type, control macOS UI";
    linux = false;
  };

  sag = {
    tool = "sag";
    description = "Text-to-speech";
    linux = true;
  };

  camsnap = {
    tool = "camsnap";
    description = "Take photos from connected cameras";
    linux = true;
  };

  gogcli = {
    tool = "gogcli";
    description = "Google Calendar integration";
    linux = true;
  };

  goplaces = {
    tool = "goplaces";
    description = "Google Places API (New) CLI";
    defaultEnable = true;
    linux = true;
  };

  bird = {
    tool = "bird";
    description = "Twitter/X integration";
    linux = false;
  };

  sonoscli = {
    tool = "sonoscli";
    description = "Control Sonos speakers";
    linux = true;
  };

  imsg = {
    tool = "imsg";
    description = "Send/read iMessages";
    linux = false;
  };
}
