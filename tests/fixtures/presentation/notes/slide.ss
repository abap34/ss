import std:themes/default as *

page introduction
pagectx().notes = <<
Introduce the problem.
Explain what the audience should take away.
>>
heading!("Project overview")
text!("Press S to see speaker notes, the next slide, and the timer.")
text!("Regular text, **bold text**, and emoji 👋 🎉")
end

page conclusion
pagectx().notes = <<
Summarize the result.
Leave time for questions.
>>
heading!("Next steps")
text!("Open the presenter view in a separate window for a second display.")
end
