import std:themes/default as *

page integration
  heading! "Monte Carlo integration"
  let body_value = text <<
Let $f$ return 1 inside the circle and 0 outside.

$$
\begin{aligned}
\pi &= \int_{[-1,1]^2} f(x,y)\,dx\,dy\\
\widehat{\pi} &= \frac{4}{N}\sum_{i=1}^{N}f(X_i,Y_i)
\end{aligned}
$$
>>
  let content = place!(body_value // text("The base letters keep the surrounding text size.", default_theme().note))
  let body = first(children(content))
  ~ body.width == 540
end
