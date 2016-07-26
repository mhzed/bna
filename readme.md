# bna

A humble little utility that does a few things:

* figure out npm package dependencies by scanning source code.  Useful when you didn't forgot "--save" option when
  calling npm,  or to figure out which packages are no longer needed.
* code "fusion", kind of like browserify or webpack:
    - supports CommonJS style require only
    - properly handles circular require, as nodejs does, unlike browserify. 
    - sourcemap files will be fused if exists. 
    - also detect the binary modules (.node files): it will copy them to where the generated js is
    - able to handle dynamic requires, in most cases.
    - real time file watch.
    - support jsx file.

## Installation

npm install -g bna

## Usage

To get help

    bna

Go to your node projects' root directory (where package.json is), run

    bna .

This will spit out the npm package dependencies by the content of your javascript source code.

## Use case

Figure the true npm package dependencies by analyzing javascript source code, because code never lies.  

* bna ignores the files excluded in .npmignore 

Fusing generates a single js file application for application distribution.  Send user two files: ./node + myapp.js, instead
of ./node + myapp.js + <thousands of node_modules containing millions of files>

* the required module name is case senstive for fuse.  Watch out on osx and windows
  where the file path is case insensitive.  Fix this in the future.

Example:

    cd .../myprogram/
    bna -f bin/myprogram.js 
    Generated myprogram.fused.js
    
    node myprogram.fused.js
    # is equivalent of
    node bin/myprogram.js
    
    # then obfuscate/minify it
    uglifyjs myprogram.fused.js -c -m > myprogram.fused.min.js

 
While in development, it's convenient to add file watchers for fuse:

    bna -f app.js -w
    
When app.js or any of the dependencies change, fuse will re-run.

## react-native

Default react native server does not resolve linked module, use bna instead.

## credits

If you find this useful, make sure you head to https://marijnhaverbeke.nl/fund/
make a donation.  Facebook should have bankrolled him, given how dependent
react native is on acorn.  But until then, let us the 99% support each other.

