var log = require("./log");

module.exports = B;

log.push("b1");
var A = require("./a.js");
log.push("b2");

require("./inherits.js")(B, A);

function B() {
    B.super.call(this);
    this.b = 'b'
}
this.BB = 'bb';