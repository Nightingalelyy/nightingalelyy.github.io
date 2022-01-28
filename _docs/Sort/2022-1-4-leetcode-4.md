---
title: Leetcode-4. Median of Two Sorted Arrays
author: Yuyang Liu
date: 2022-1-4
category: Sort
order: 1
---

Description:

Given two sorted arrays nums1 and nums2 of size m and n respectively, return the median of the two sorted arrays.

The overall run time complexity should be O(log (m+n)).


 

Example 1:

Input: nums1 = [1,3], nums2 = [2]

Output: 2.00000

Explanation: merged array = [1,2,3] and median is 2.

Example 2:

Input: nums1 = [1,2], nums2 = [3,4]

Output: 2.50000

Explanation: merged array = [1,2,3,4] and median is (2 + 3) / 2 = 2.5.



Constraints:

nums1.length == m

nums2.length == n

0 <= m <= 1000

0 <= n <= 1000

1 <= m + n <= 2000

-10<sup>6</sup> <= nums1[i], nums2[i] <= 10<sup>6</sup>

Solution：

Use two pointer, backward and forward, then use shellsort, needn't use vector or array to save the data that have sorted, all we need is the median of one or two number, if the size is odd, return forward, otherwise return (backward+forward)/2


Code: 

``` c++
class Solution {
public:
    double findMedianSortedArrays(vector<int>& nums1, vector<int>& nums2) {
        double Forward,Backward; 
        int point1=0,point2=0;
        int count=0;
        bool isOdd=true;
        int m=nums1.size()+nums2.size();
        if(m%2==0) isOdd=false;
        m=m/2+1;
        bool Finish1=false,Finish2=false;
        if(point1==nums1.size()) Finish1=true;
        if(point2==nums2.size()) Finish2=true;
        while(count<m)
        {
            if(Finish1)
            {
                ++count;
                Backward=Forward;
                Forward=nums2[point2++];
            }
            else if(Finish2)
            {
                ++count;
                Backward=Forward;
                Forward=nums1[point1++];
            }
            else if(nums1[point1]<nums2[point2])
            {
                ++count;
                Backward=Forward;
                Forward=nums1[point1++];
                if(point1==nums1.size()) Finish1=true;
            }
            else
            {
                ++count;
                Backward=Forward;
                Forward=nums2[point2++];
                if(point2==nums2.size()) Finish2=true;
            }
                
        }
    
        if (isOdd) return(Forward);
        else
        return((Forward+Backward)/2);
    }
};
static int a = [](){ios::sync_with_stdio(NULL);return 0;}();
```
