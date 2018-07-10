pragma solidity ^0.4.24;

library DateTimeUtility {
    
    function toGMT(uint256 _unixtime) 
        pure 
        internal 
        returns(uint32, uint8, uint8, uint8, uint8, uint8)
    {
        // http://ptspts.blogspot.com/2009/11/how-to-convert-unix-timestamp-to-civil.html
        uint256 secs = _unixtime % 86400;
        
        _unixtime /= 86400;
        uint256 e = (_unixtime * 4 + 102032) / 146097 + 15;
        e = _unixtime + 2442113 + e - (e / 4);
        uint256 c = (e * 20 - 2442) / 7305;
        uint256 d = e - 365 * c - c / 4;
        e = d * 1000 / 30601;
        
        if (e < 14) {
            return (uint32(c - 4716)
                , uint8(e - 1)
                , uint8(d - e * 30 - e * 601 / 1000)
                , uint8(secs / 3600)
                , uint8(secs / 60 % 60)
                , uint8(secs % 60));
        } else {
            return (uint32(c - 4715)
                , uint8(e - 13)
                , uint8(d - e * 30 - e * 601 / 1000)
                , uint8(secs / 3600)
                , uint8(secs / 60 % 60)
                , uint8(secs % 60));
        }
    } 
    
    function toUnixtime(uint32 _year, uint8 _month, uint8 _mday, uint8 _hour, uint8 _minute, uint8 _second) 
        pure 
        internal 
        returns (uint256)
    {
        // http://ptspts.blogspot.com/2009/11/how-to-convert-unix-timestamp-to-civil.html
        
        uint256 m = uint256(_month);
        uint256 y = uint256(_year);
        if (m <= 2) {
            y -= 1;
            m += 12;
        }
        
        return (365 * y + y / 4 -  y/ 100 + y / 400 + 3 * (m + 1) / 5 + 30 * m + uint256(_mday) - 719561) * 86400 
            + 3600 * uint256(_hour) + 60 * uint256(_minute) + uint256(_second);
    }
}