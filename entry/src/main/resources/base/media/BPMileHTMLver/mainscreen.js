(function () {
    'use strict';

    var choosearea = document.getElementById('choosearea');
    var circle1 = document.getElementById('circle1');
    var circle2 = document.getElementById('circle2');

    var isCircle1Active = true;

    function setCircle1Active() {
        isCircle1Active = true;
        circle1.style.left = '50%';
        circle1.style.transform = 'translate(-50%, -50%)';
        circle2.style.left = 'calc(100% - 30px)';
        circle2.style.transform = 'translateY(-50%)';
    }

    function setCircle2Active() {
        isCircle1Active = false;
        circle1.style.left = 'calc(-25vh + 30px)';
        circle1.style.transform = 'translateY(-50%)';
        circle2.style.left = '50%';
        circle2.style.transform = 'translate(-50%, -50%)';
    }

    choosearea.addEventListener('click', function (e) {
        var rect = choosearea.getBoundingClientRect();
        var clickX = e.clientX - rect.left;
        var halfWidth = rect.width / 2;

        if (clickX > halfWidth) {
            if (isCircle1Active) {
                setCircle2Active();
            }
        } else {
            if (!isCircle1Active) {
                setCircle1Active();
            }
        }
    });
})();