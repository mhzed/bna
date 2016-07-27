# bna


A humble little utility for people who use CommonJS "require".  It does a few things:

* figure out true npm package dependencies by scanning "require" in source code, because code never lies (almost).
* code "fusion": generate a single js that merges all required code together.  The resulting
  js can be run in any javascript runtime (provided any of the required code also run anywhere,
  of course).  :
    - properly handles circular require, as nodejs does. 
    - able to handle dynamic requires (require anything other than a string literal), in most cases.
    - support react jsx file.
    - sourcemap files will be fused if exists. 
    - also detect the nodejs binary modules (.node files): it will copy them to where the generated js is
    - real time file watch:  re-fuse if any of the dependencies change.
    

## Installation

npm install -g bna

## Usage

To get help

    bna

Go to your node projects' root directory (where package.json is), run

    bna .

This will spit out the npm package dependencies.

## Use case

### Package dependency managament

Figure out the true npm package dependencies by analyzing javascript source code.  During a development
lifecycle, modules required change constantly and after a while you can't really trust package.json.  bna will
scan your js code to figure out what modules that you code truely "require".

* bna ignores the files excluded in .npmignore

### Code fusion

#### Build a js app for distribution

Fuse generates a single js file application for application distribution.  Send user two files: ./node + myapp.js, instead
of ./node + myapp.js + <thousands of node_modules containing millions of files>

* the required module name is case sensitive for fuse.  So watch out on osx and windows
  where the file path is case insensitive.  TODO: worth fixing?

Example:

    # generate a single runnable js
    bna -f bin/myprogram.js 
    Generated myprogram.fused.js
    
    # then obfuscate/minify it
    uglifyjs myprogram.fused.js -c -m > myprogram.fused.min.js
    
While in development, it's convenient to add file watchers for hot reloading:

    bna -f app.js -w
    
When app.js or any of the dependencies change, fuse will re-run.  The dependencies here refer to all of the
javascript files that app.js require directly or indirectly.

#### Single page webapp

Same idea as browserify or webpack.

1. handles circular require properly
2. handles require non-string literal properly (except in the most contrived corner cases)
3. does not poly-fill the nodjs apis for browser.  For non IO related nodejs apis, you
   can find the pure JS implementation easily in github.


#### react-native

Default react native server does not resolve linked npm module, bna does.  

TODO: write a guide here

## credits

If you find this useful, make sure you head to https://marijnhaverbeke.nl/fund/
to make a donation.  Facebook should have bankrolled him, as react-native switched
to acorn.  But until then, let us the 99% support each other.

