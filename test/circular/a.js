var log = require("./log");

module.exports = A;

log.push("a1");
var B = require("./b.js");
var C = require("./c.js");
log.push("a2");
function A() {
    this.a = 'a';
}
this.AA = 'aa';