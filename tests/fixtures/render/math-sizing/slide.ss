import std:themes/default as *

page integration
  head! "Monte Carlo integration"
  let body = text! <<
Let $f$ return 1 inside the circle and 0 outside.

$$
\begin{aligned}
\pi &= \int_{[-1,1]^2} f(x,y)\,dx\,dy\\
\widehat{\pi} &= \frac{4}{N}\sum_{i=1}^{N}f(X_i,Y_i)
\end{aligned}
$$
>>
  ~ body.width == 540
  body // note! "The base letters keep the surrounding text size."
end
